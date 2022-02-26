import math, stats
import ingrid / ingrid_types
import helpers / utils
import logging
import ingrid / private / [pure, cdl_cuts, clustering]

import sequtils, nlopt
import arraymancer # for tensor and dbscan

#[
This module contains (among others) the actual ``reconstruction`` calculations
done by `reconstruction.nim`, that is those calculation, which are not part of
the calibration steps (via `--only_*` flags), but instead concern the conversion
from raw data to reconstructed data. This is basically cluster finding and
rotation angle / geometrical property calcuations.
]#

type
  # fit object, which is handed to the NLopt library in the
  # `VarStruct` -> to the eccentricity function
  FitObject[T: SomePix] = object
    cluster: Cluster[T]
    xy: tuple[x, y: float64]

macro hijackMe(procImpl: untyped): untyped =
  when defined(activateHijack) and declared(replaceBody):
    replaceBody(procImpl)
  else:
    procImpl

################################################################################
############# Geometry calculation related procs ###############################
################################################################################

proc newClusterGeometry*(): ClusterGeometry =
  result = ClusterGeometry(rmsLongitudinal: Inf,
                           rmsTransverse: Inf,
                           eccentricity: Inf,
                           rotationAngle: Inf,
                           skewnessLongitudinal: Inf,
                           skewnessTransverse: Inf,
                           kurtosisLongitudinal:Inf,
                           kurtosisTransverse: Inf,
                           length: Inf,
                           width: Inf,
                           fractionInTransverseRms: Inf)


proc newClusterObject*[T: SomePix](timepix: TimepixVersion): ClusterObject[T] =
  ## initialize variables with Inf for now
  # TODO: should we initialize geometry values by Inf as well?
  let geometry = ClusterGeometry()
  result = ClusterObject[T](centerX: Inf,
                            centerY: Inf,
                            energy: Inf,
                            geometry: geometry,
                            version: timepix)

proc to*[T: SomePix; U: SomePix](c: Cluster[T], _: typedesc[U]): Cluster[U] =
  ## Converts the input pix type to the output
  ## May throw away information
  when T is U: result = c
  elif T is Pix and U is PixTpx3:
    # return with empty `toa`, `toaCombined`
    warn("Conversion from `Pix` to `PixTpx3` adds empty ToA data!")
    result = newSeq[U](c.len)
    for i in 0 ..< result.len:
      result[i] = (x: c[i].x, y: c[i].y, ch: c[i].ch, toa: 0'u16, toaCombined: 0'u64)
  elif T is PixTpx3 and U is Pix:
    warn("Conversion from `PixTpx3` to `Pix` throws away ToA information!")
    result = newSeq[U](c.len)
    for i in 0 ..< result.len:
      result[i] = (x: c[i].x, y: c[i].y, ch: c[i].ch)
  elif T is PixInt or U is PixInt:
    error("Currently unsupported for `PixInt` type! Need to make sure we perform " &
      "coordinate transformation correctly!")

template withSeptemXY*(chipNumber: int, actions: untyped): untyped =
  ## injects the x0, y0 coordinates of the given chip number embedded into
  ## the septem frame
  var
    x0 {.inject.}: int
    y0 {.inject.}: int
  case chipNumber
  of 0:
    # chip bottom left of board
    y0 = 0 # top end of bottom row
    x0 = 128 # shifted by half a chip to the right
  of 1:
    # chip bottom right
    y0 = 0
    x0 = 128 + 256
  of 2:
    # middle left
    y0 = 256
    x0 = 0
  of 3:
    # middle middle
    y0 = 256
    x0 = 256
  of 4:
    # middle right
    y0 = 256
    x0 = 2 * 256
  of 5:
    # top right chip (- 1 as we start at top/right, which would be out of bounds if x/y == 0
    #                 for other chips x/y == 0 leads to first idx on next chip)
    y0 = 3 * 256 - 1
    x0 = 2 * 256 + 127
  of 6:
    # top left chip
    y0 = 3 * 256 - 1
    x0 = 256 + 127
  else: doAssert false, "Invalid chip number encountered in `withSeptemXY`"
  actions

func determineChip*[T:  SomePix](p: T): int =
  ## determines which chip the given septem pixel coordinate corresponds to
  if p.y in 0 .. 255 and p.x in 128 .. 128 + 255:
    # bottom left
    result = 0
  elif p.y in 0 .. 255:
    # bottom right
    result = 1
  elif p.y in 256 .. 511 and p.x in 0 .. 255:
    # middle left
    result = 2
  elif p.y in 256 .. 511 and p.x in 256 .. 511:
    # center
    result = 3
  elif p.y in 256 .. 511:
    # middle right
    result = 4
  elif p.x in 128 + 256 .. 512 + 127:
    # top right
    result = 5
  elif p.x in 128 .. 128 + 255:
    # top left
    result = 6
  else:
    raise newException(Exception, "This chip should not exist! " & $p)

func septemPixToChpPix*[T: SomePix](p: T, chipNumber: range[0 .. 6]): T =
  ## inverse of chpPixToSeptemPix
  result = p
  case chipNumber
  of 0:
    # chip bottom left of board
    result.x = result.x - 128 # shifted by half a chip to the right
  of 1:
    # chip bottom right
    result.x = result.x - (128 + 256)
  of 2:
    # middle left
    result.y = result.y - 256
  of 3:
    # middle middle
    result.y = result.y - 256
    result.x = result.x - 256
  of 4:
    # middle right
    result.y = result.y - 256
    result.x = result.x - 512
  of 5:
    # top right chip
    result.y = -(result.y - 3 * 256)
    result.x = -(result.x - (2 * 256 + 128))
  of 6:
    # top left chip
    result.y = -(result.y - 3 * 256)
    result.x = -(result.x - (128 + 256))

func chpPixToSeptemPix*(p: Pix, chipNumber: range[0 .. 6]): PixInt =
  ## converts the given local chip pixel to the full septem frame coordinate system
  withSeptemXY(chipNumber):
    var xIdx, yIdx: int
    case chipNumber
    of 0, 1, 2, 3, 4:
      xIdx = x0 + p.x.int
      yIdx = y0 + p.y.int
    of 5, 6:
      xIdx = x0 - p.x.int
      yIdx = y0 - p.y.int
    result = (x: min(xIdx, 767), y: min(yIdx, 767), ch: p.ch.int)

func chpPixToSeptemPix*(pix: Pixels, chipNumber: range[0 .. 6]): PixelsInt =
  ## converts the given local chip pixels to the full septem frame coordinate system
  result.setLen(pix.len)
  for i, p in pix:
    let pp = chpPixToSeptemPix(p, chipNumber)
    result[i] = pp

# proc sum*[T: tuple](s: seq[T]): T {.inline.} =
#   # this procedure sums the given array along the given axis
#   # if T is itself e.g. a tuple, we will return a tuple, one
#   # element for each field in the tuple
#   assert s.len > 0, "Can't sum empty sequences"
#   var sum_t: T
#   for p in s:
#     for n, f in fieldPairs(p):
#       sum_t[f] += p[n]

proc calcCentroidOfEvent*(pix: Pixels): tuple[x, y: float] =
  ## proc to calc centroid of the given pixels
  ## inputs:
  ##    pixels object (seq[tuple[x, y, ch: int]]) containing raw event
  ## outputs:
  ##    tuple[x, y: int]: tuple containing centroid x and y position
  ## let x = map(pix, (p: tuple[x, y, ch: int]) -> int => p.x)
  ## let y = map(pix, (p: tuple[x, y, ch: int]) -> int => p.y)
  ## let sum_x = foldl(x, a + b)
  ## let sum_y = foldl(y, a + b)
  var
    sum_x: int = 0
    sum_y: int = 0
  for p in pix:
    sum_x += p.x.int
    sum_y += p.y.int
  #let (sum_x, sum_y, sum_ch) = sum(pix)
  result.x = float(sum_x) / float(len(pix))
  result.y = float(sum_y) / float(len(pix))


proc isNearCenterOfChip*(pix: Pixels): bool =
  ## proc to check whether event is located around center of chip
  ## inputs:
  ##    pixels object (seq[tuple[x, y, ch: int]]) containing raw event
  ## outputs:
  ##    true if within 4.5mm center square, false otherwise
  if true: quit("`isNearCenterOfChip` is broken!")
  let (center_x, center_y) = calcCentroidOfEvent(pix)
  # pitch in um
  let pitch = 0.05
  let n_pix_to_bound = 2.25 / pitch
  # center pixel is (127, 127)
  let center_pix = 127'f
  var
    in_x = false
    in_y = false
  if center_x > (center_pix - n_pix_to_bound) and center_x < (center_pix + n_pix_to_bound):
    in_x = true
  if center_y > (center_pix - n_pix_to_bound) and center_y < (center_pix + n_pix_to_bound):
    in_y = true
  if in_x == true and in_y == true:
    result = true
  else:
    result = false

# template which calculates euclidean distance between 2 points
template distance*(x, y: float): float = sqrt(x * x + y * y)

# template which returns pitch converted positions on chip pixel values
# to mm from center of chip
# constants are:
# const NPIX = 256
# const PITCH = 0.0055 (see ingrid_types)
func applyPitchConversion*[T: (float | SomeInteger)](x, y: T, npix: int): (float, float) =
  ## template which returns the converted positions on a Timepix
  ## pixel position --> position from center in mm
  ((float(npix) - float(x) + 0.5) * PITCH, (float(y) + 0.5) * PITCH)

func inRegion*(centerX, centerY: float, region: ChipRegion): bool {.inline.} =
  ## returns the result of a cut on a certain chip `region`. Inputs the
  ## `centerX` and `centerY` position of a cluster and returns true if
  ## the cluster is within the region
  const centerChip = 7.0
  case region
  of crGold:
    # make sure this is only initialized once somehow...
    let regCut = getRegionCut(region)
    result = if centerX >= regCut.xMin and
                centerX <= regCut.xMax and
                centerY >= regCut.yMin and
                centerY <= regCut.yMax:
               true
             else:
               false
  of crAll:
    # simply always return good
    result = true
  else:
    # make sure this is only initialized once somehow...
    let regCut = getRegionCut(region)
    # silver and bronze region only different by radius
    let
      xdiff = (centerX - centerChip)
      ydiff = (centerY - centerChip)
      radius = distance(xdiff, ydiff)
    # TODO: gold cut is NOT part of the silver region (see C. Krieger PhD p. 133)
    result = if radius <= regCut.radius: true else : false

proc eccentricity[T: SomePix](p: seq[float], func_data: FitObject[T]): float =
  ## this function calculates the eccentricity of a found pixel cluster using nimnlopt.
  ## Since no proper high level library is yet available, we need to pass a var pointer
  ## of func_data, which contains the x and y arrays in which the data is stored, in
  ## order to calculate the RMS variables
  # first recover the data from the pointer to func_data, by casting the
  # raw pointer to a Cluster object
  let fit = func_data
  let c = fit.cluster
  let (centerX, centerY) = fit.xy

  var
    sum_x: float = 0
    sum_y: float = 0
    sum_x2: float = 0
    sum_y2: float = 0

  for i in 0..<len(c):
    let
      new_x = cos(p[0]) * (c[i].x.float - centerX) * PITCH - sin(p[0]) * (c[i].y.float - centerY) * PITCH
      new_y = sin(p[0]) * (c[i].x.float - centerX) * PITCH + cos(p[0]) * (c[i].y.float - centerY) * PITCH
    sum_x += new_x
    sum_y += new_y
    sum_x2 += (new_x * new_x)
    sum_y2 += (new_y * new_y)

  let
    n_elements: float = len(c).float
    rms_x: float = sqrt( (sum_x2 / n_elements) - (sum_x * sum_x / n_elements / n_elements))
    rms_y: float = sqrt( (sum_y2 / n_elements) - (sum_y * sum_y / n_elements / n_elements))

  # calc eccentricity from RMS
  let exc = rms_x / rms_y
  result = -exc

proc calcGeometry*[T: SomePix](cluster: Cluster[T],
                               pos_x, pos_y, rot_angle: float): ClusterGeometry =
  ## given a cluster and the rotation angle of it, calculate the different
  ## statistical moments, i.e. RMS, skewness and kurtosis in longitudinal and
  ## transverse direction
  ## done by rotating the cluster by the angle to define the two directions
  let npix = cluster.len

  var
    xRot = newSeq[float](npix)
    yRot = newSeq[float](npix)
    radius: float
    x_max, x_min: float
    y_max, y_min: float
    i = 0
  for p in cluster:
    when T is Pix or T is PixTpx3:
      let (x, y) = applyPitchConversion(p.x, p.y, NPIX)
    elif T is PixInt:
      let (x, y) = applyPitchConversion(p.x, p.y, NPIX * 3)
    else:
      error("Invalid type: " & $T)
    xRot[i] = cos(-rot_angle) * (x - pos_x) - sin(-rot_angle) * (y - pos_y)
    yRot[i] = sin(-rot_angle) * (x - pos_x) + cos(-rot_angle) * (y - pos_y)

    # calculate distance from center
    let dist = distance(xRot[i], yRot[i])
    if dist > radius:
      radius = dist
    inc i
  # define statistics objects
  var
    stat_x: RunningStat
    stat_y: RunningStat
  # and push our new vectors to them
  stat_x.push(xRot)
  stat_y.push(yRot)

  # now we have all data to calculate the geometric properties
  result.length               = max(xRot) - min(xRot)
  result.width                = max(yRot) - min(yRot)
  result.rmsTransverse        = stat_y.standardDeviation()
  result.rmsLongitudinal      = stat_x.standardDeviation()
  result.skewnessTransverse   = stat_y.skewness()
  result.skewnessLongitudinal = stat_x.skewness()
  result.kurtosisTransverse   = stat_y.kurtosis()
  result.kurtosisLongitudinal = stat_x.kurtosis()
  result.rotationAngle        = rot_angle
  result.eccentricity         = result.rmsLongitudinal / result.rmsTransverse
  # get fraction of all pixels within the transverse RMS, by filtering all elements
  # within the transverse RMS radius and dividing by total pix
  # when not defined(release):
  #   # DEBUG
  #   echo "rms trans is ", result.rmsTransverse
  #   echo "std is ", stat_y.variance()
  #   echo "thus filter is ", filterIt(zip(xRot, yRot), distance(it.a, it.b) <= result.rmsTransverse)
  result.lengthDivRmsTrans = result.length / result.rmsTransverse
  result.fractionInTransverseRms = (
    filterIt(zip(xRot, yRot),
             distance(it[0], it[1]) <= result.rmsTransverse).len
  ).float / float(npix)

proc calcToAGeometry*[T: SomePix](cluster: var ClusterObject[T]): ToAGeometry =
  ## Given a cluster, computes different ToA based "geometric" properties (i.e.
  ## the length in ToA etc.) and also (hence `cluster` is `var`) modifies the
  ## `toa` field such that each cluster starts at 0.

  ## XXX: `toaLength` is already computed in `raw_data_manipulation` as `length` field of
  ## the `ProcessedRun`!
  var minToA = uint16.high
  var maxToA = 0'u16
  for i, toa in cluster.toa:
    minToA = min(minToA, toa)
    maxToA = max(maxToA, toa)
  ## use min ToA knowledge to push subtracted values to stat and modify `toa`
  var
    stat: RunningStat
  for i, toa in mpairs(cluster.toa):
    let toaZ = toa.int - minToA.int
    stat.push(toaZ.float)
    doAssert toaZ >= 0
    toa = toaZ.uint16
  ## Cannot safely treat `toaLength` as uint16 due to underflow danger
  result.toaLength = (maxToA.float - minToA.float)
  result.toaMean = stat.mean()
  result.toaRms = stat.standardDeviation()
  result.toaMin = minToA

proc isPixInSearchRadius[T: SomeInteger](p1, p2: Coord[T], search_r: int): bool =
  ## given two pixels, p1 and p2, we check whether p2 is within one square search
  ## of p1
  ## inputs:
  ##   p1: Pix = pixel from which to start search
  ##   p2: Pix = pixel for which to check
  ##   search_r: int = search radius (square) in which to check for p2 in (p1 V search_r)
  ## outpuits:
  ##   bool = true if within search_r
  ##          false if not

  # XXX: THIS searches in a ``*square*``. Add option to search in a ``*circle*``
  let
    # determine boundary of search space
    right = p1.x.int + search_r
    left  = p1.x.int - search_r
    up    = p1.y.int + search_r
    down  = p1.y.int - search_r
  # NOTE: for performance we may want to use the fact that we may know that
  # p1 is either to the left (if in the same row) or below (if not in same row)
  var
    in_x: bool = false
    in_y: bool = false

  if p2.x.int < right and p2.x.int > left:
    in_x = true
  if p2.y.int < up and p2.y.int > down:
    in_y = true
  result = if in_x == true and in_y == true: true else: false

proc wrapDbscan(p: Tensor[float], eps: float, minSamples: int): seq[int] =
  ## This is a wrapper around `dbscan`. Without it for some reason `seqmath's` `arange`
  ## is bound in the context of the `kdtree` code for some reason (binding manually is
  ## no help, neither here nor in `reconstruction.nim`)
  dbscan(p, eps, minSamples)

proc findClusterDBSCAN*[T: SomePix](pixels: seq[T], eps: float = 65.0,
                                    minSamples: int = 3): seq[Cluster[T]] =
  var pT = newTensorUninit[float]([pixels.len, 2])
  for i, tup in pixels:
    pT[i, _] = [tup.x.float, tup.y.float].toTensor.unsqueeze(axis = 0)
  if pixels.len == 0: return
  let clusterIdxs = wrapDbscan(pT, eps, minSamples)
  for i, clIdx in clusterIdxs:
    if clIdx == -1: continue
    if clIdx >= result.len:
      result.setLen(clIdx+1)
    if result[clIdx].len == 0:
      result[clIdx] = newSeqOfCap[T](pixels.len)
    result[clIdx].add pixels[i]

proc eccentricityNloptOptimizer[T: SomePix](fitObject: FitObject[T]):
  NloptOpt[FitObject[T]] =
  ## returns the already configured Nlopt optimizer to fit the rotation angle /
  ## eccentricity
  var
    # set the boundary values corresponding to range of 360 deg
    lb = (-4.0 * arctan(1.0), 4.0 * arctan(1.0))
  type tFitObj = type(fitObject)
  result = newNloptOpt[tFitObj](LN_BOBYQA, 1, @[lb])
  # hand the function to fit as well as the data object we need in it
  # NOTE: workaround for https://github.com/nim-lang/Nim/issues/11778
  var varStruct = VarStruct[tFitObj](userFunc: eccentricity, data: fitObject,
                                     kind: nlopt.FuncKind.NoGrad)
  result.setFunction(varStruct)
  # set relative precisions of x and y, as well as limit max time the algorithm
  # should take to 1 second
  # these default values have proven to be working
  result.xtol_rel = 1e-8
  result.ftol_rel = 1e-8
  result.maxtime  = 1.0
  result.initial_step = 0.02

proc fitRotAngle*[T: SomePix](cl_obj: ClusterObject[T],
                              rotAngleEstimate: float): (float, float) = #{.hijackMe.} =
  ## Performs the fitting of the rotation angle on the given ClusterObject
  ## `cl_obj` and returns the final parameters as well as the minimum
  ## value at those parameters.
  # set the fit object with which we hand the necessary data to the
  # eccentricity function
  var fit_object = FitObject[T](cluster: cl_obj.data,
                                xy: (x: cl_obj.centerX, y: cl_obj.centerY))
  var opt = eccentricityNloptOptimizer(fit_object)
  # start minimization
  var p = @[rotAngleEstimate]
  let (params, min_val) = opt.optimize(p)
  if opt.status < NLOPT_SUCCESS:
    info opt.status
    warn "nlopt failed!"
  # clean up optimizer
  destroy(opt)
  # now return the optimized parameters and the corresponding min value
  result = (params[0], min_val)


#proc recoCluster*(c: Cluster[Pix]): ClusterObject[Pix] {.gcsafe.} =
proc recoCluster*[T: SomePix; U: SomePix](c: Cluster[T],
                                          timepix: TimepixVersion = Timepix1,
                                          _: typedesc[U]): ClusterObject[U] {.gcsafe, hijackMe.} =
  result = newClusterObject[U](timepix)

  let clustersize: int = len(c)
  ##
  const NeedConvert = T is PixTpx3 and U is Pix
  var cl = newSeq[U](clustersize)
  var
    sum_x, sum_x2: int
    sum_y, sum_y2, sum_xy: int
    sum_ToT: int
    minToA: uint16
  when T is PixTpx3:
    result.toa = newSeq[uint16](clustersize)
    result.toaCombined = newSeq[uint64](clustersize)
  for i in 0 ..< clustersize:
    let ci = c[i]
    sum_x  += ci.x.int
    sum_y  += ci.y.int
    sumToT += ci.ch.int
    sum_x2 += ci.x.int * ci.x.int
    sum_y2 += ci.y.int * ci.y.int
    sum_xy += ci.x.int * ci.y.int
    when NeedConvert:
      cl[i] = (x: ci.x, y: ci.y, ch: ci.ch)
      result.toa[i] = ci.toa
      result.toaCombined[i] = ci.toaCombined
  when NeedConvert:
    result.data = cl
  else:
    result.data = c
  let
    pos_x = float64(sum_x) / float64(clustersize)
    pos_y = float64(sum_y) / float64(clustersize)
  var
    rms_x = sqrt(float64(sum_x2) / float64(clustersize) - pos_x * pos_x)
    rms_y = sqrt(float64(sum_y2) / float64(clustersize) - pos_y * pos_y)
    rotAngleEstimate = arctan( (float64(sum_xy) / float64(clustersize)) -
                               pos_x * pos_y / (rms_x * rms_x))

  # set the total "charge" in the cluster (sum of ToT values), can be
  # converted to electrons with ToT calibration
  result.sum_tot = sumTot
  # set number of hits in cluster
  result.hits = clustersize
  # set the position
  when T is Pix or T is PixTpx3:
    (result.centerX, result.centerY) = applyPitchConversion(pos_x, pos_y, NPIX)
  elif T is PixInt:
    (result.centerX, result.centerY) = applyPitchConversion(pos_x, pos_y, NPIX * 3)
  else:
    error("Invalid type: " & $T)
  # prepare rot angle fit
  if rotAngleEstimate < 0:
    #echo "correcting 1"
    rotAngleEstimate += 8 * arctan(1.0)
  if rotAngleEstimate > 4 * arctan(1.0):
    #echo "correcting 2"
    rotAngleEstimate -= 4 * arctan(1.0)
  elif classify(rotAngleEstimate) != fcNormal:
    warn "Rot angle estimate is NaN, vals are ", $rms_x, " ", $rms_y
    # what do we do in this case with the geometry?!
    #raise newException(ValueError, "Rotation angle estimate returned bad value")
    warn "Fit will probably fail!"

  # else we can minimize the rotation angle and calc the eccentricity
  let (rot_angle, eccentricity) = fitRotAngle(result, rotAngleEstimate)

  # now we still need to use the rotation angle to calculate the different geometric
  # properties, i.e. RMS, skewness and kurtosis along the long axis of the cluster
  result.geometry = calcGeometry(c, result.centerX, result.centerY, rot_angle)
  when T is PixTpx3:
    result.toaGeometry = calcToAGeometry(result)


proc getPixels[T](dat: RecoInputEvent, _: typedesc[T]): seq[T] =
  when T is Pix:
    result = dat.pixels
  elif T is PixTpx3:
    doAssert dat.pixels.len == dat.toa.len
    result = newSeq[PixTpx3](dat.pixels.len)
    for i in 0 ..< result.len:
      result[i] = (x: dat.pixels[i].x, y: dat.pixels[i].y, ch: dat.pixels[i].ch,
                   toa: dat.toa[i], toaCombined: dat.toaCombined[i])
  else:
    error("Invalid type : " & $T)

proc recoEvent*[T: SomePix](dat: RecoInputEvent[T],
                            chip, run, searchRadius: int,
                            dbscanEpsilon: float,
                            clusterAlgo: ClusteringAlgorithm,
                            timepixVersion = Timepix1): RecoEvent[T] {.gcsafe, hijackMe.} =
  result.event_number = dat.eventNumber
  result.chip_number = chip

  ## NOTE: The usage of a `PixTpx3` is rather wasteful and is only done, because
  ## it's currently easier to perform the clustering using the default algorithm
  ## with such data. Otherwise we need to keep track which indices end up in what
  ## cluster.
  ## However: it may anyway be smart to avoid the logic of `deleteIntersection` and
  ## instead mark indices in a set (?) and keep track of each index being in what
  ## cluster?
  ## I remember trying *some* kind of set based approach before which turned out
  ## slower, so gotta be careful.
  template recoClusterTmpl(typ, pixels: untyped): untyped {.dirty.} =
    var cluster: seq[Cluster[typ]]
    case clusterAlgo
    of caDefault: cluster = findSimpleCluster(pixels, searchRadius)
    of caDBSCAN:  cluster = findClusterDBSCAN(pixels, dbscanEpsilon)
    result.cluster = newSeq[ClusterObject[T]](cluster.len)
    for i, cl in cluster:
      result.cluster[i] = recoCluster(cl, timepixVersion, T)

  if dat[0].len > 0:
    case timepixVersion
    of Timepix1:
      let pixels = getPixels(dat, Pix)
      recoClusterTmpl(Pix, pixels)
    of Timepix3:
      let pixels = getPixels(dat, PixTpx3)
      recoClusterTmpl(PixTpx3, pixels)
