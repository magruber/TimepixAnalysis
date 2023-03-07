import std / [os, math, random, strformat, times, stats, osproc, logging, monotimes, intsets]
import pkg / [nimhdf5, unchained, seqmath, chroma, cligen, shell]

import sequtils except repeat
from strutils import repeat, endsWith, strip, parseFloat, removeSuffix

import pkg / [sorted_seq]

import ingrid / tos_helpers
# the interpolation code
import ingrid / background_interpolation
import numericalnim except linspace, cumSum
import arraymancer except read_csv, cumSum


defUnit(keV⁻¹•cm⁻²)

# for multiprocessing
import cligen / [procpool, mslice, osUt]

type
  ChipCoord = range[0.0 .. 14.0]

  Candidate = object
    energy: keV
    pos: tuple[x, y: ChipCoord]

  ## TODO: split the different fields based on the method we want to use?
  ## SamplingKind represents the different types of candidate from background sampling we can do
  SamplingKind = enum
    skConstBackground, ## uses the constant background over the gold region. Only allows sampling in the gold region.
    skInterpBackground ## uses the interpolated background over the whole chip.

  UncertaintyKind = enum
    ukCertain, # no uncertainties
    ukUncertainSig, # uncertainty only on signal (integrated analytically)
    ukUncertainBack, # uncertainty only on background (integrated numerically)
    ukUncertain # uncertainty on both. Analytical result of ukUncertainSig integrated numerically

  PositionUncertaintyKind = enum
    puCertain   # no uncertainty
    puUncertain # use uncertainty on position

  ## Stores the relevant context variables for the interpolation method
  Interpolation = object
    kd: KDTree[float]        ## we use a KDTree to store the data & compute interpolation on top of
    backCache: Table[Candidate, keV⁻¹•cm⁻²] ## cache for the background values of a set of candidates. Used to avoid
                             ## having to recompute the values in a single MC iteration (within limit computation).
                             ## Only the signal values change when changing the coupling constants after all.
    radius: float            ## radius of background interpolation (σ is usually radius / 3.0)
    sigma: float             ## σ of the weight for, usually radius / 3.0 as mentioned above
    energyRange: keV         ## energy range of the background interpolation
    nxy: int                 ## number of points at which to sample the background interpolation in x/y
    nE: int                  ## number of points at which to sample the background interpolation in E
    xyOffset: float          ## Offset in x/y coordinates (to not sample edges). Is `coords[1] - coords[0] / 2`
    eOffset: float           ## Offset in E coordinates (to not sample edges). Is `energies[1] - energies[0] / 2`
    coords: seq[float]       ## the coordinates at which the background interpolation was evaluated to
                             ## compute the the expected counts tensor
    energies: seq[float]     ## the energy values at which the background interpolation was evaluated
                             ## to compute the expected counts tensor
    expCounts: Tensor[float] ## the tensor containing the expected counts at different (x, y, E) pairs
    backgroundTime: Hour     ## time of background data (same value as in `Context`)
    trackingTime: Hour       ## time of solar tracking (same value as in `Context`)
    # these are always valid for a single `computeLimit` call!
    zeroSig: int             ## counts the number of times the expected signal was 0
    zeroBack: int            ## counts the number of times the background was 0
    zeroSigBack: int         ## counts the number of times the signal & background was zero

  ## Stores the current state of the systematics. Allows to easier replace the kind &
  ## value of systematics at RT without having to change the kind of the `Context`.
  ## Note: for backward compat there are templates to access `ctx.systematics.X`.
  Systematics = object
    case uncertainty: UncertaintyKind
    of ukUncertainSig:
      σs_sig: float # Uncertainty on signal in relative terms, percentage
    of ukUncertainBack:
      σb_back: float # Uncertainty on background in relative terms, percentage
    of ukUncertain: ## annoying....
      σsb_sig: float
      σsb_back: float
    else: discard
    # uncertainty on the center position of the signal
    case uncertaintyPosition: PositionUncertaintyKind
    of puUncertain:
      σ_p: float # relative uncertainty away from the center of the chip, in units of
                # ???
      θ_x: float
      θ_y: float
    of puCertain: discard # no uncertainty

  Context = ref object ## XXX: make ref object
    mcIdx: int # monte carlo index, just for reference
    axionModel: DataFrame
    integralBase: float # integral of axion flux using base coupling constants
    # detector related
    windowRotation: Degree # rotation of the window during data taking
    # interpolators
    axionSpl: InterpolatorType[float]
    efficiencySpl: InterpolatorType[float]
    raytraceSpl: Interpolator2DType[float]
    backgroundSpl: InterpolatorType[float]
    # background candidate sampling
    backgroundDf: DataFrame # the DataFrame containing all background cluster data
    backgroundCDF: seq[float] # CDF of the background
    energyForBCDF: seq[float] # energies to draw from for background CDF
    totalBackgroundClusters: int # total number of background clusters in non-tracking time
    totalBackgroundTime: Hour # total time of background data taking
    totalTrackingTime: Hour # total time of solar tracking
    case samplingKind: SamplingKind # the type of candidate sampling we do
    of skInterpBackground:
      interp: Interpolation ## A helper object to store all interpolation fields
    else: discard # skConstant doesn't need
    # limit related
    couplingStep: float # a step we take in the couplings during a scan
    g_aγ²: float # the reference g_aγ (squared)
    g_ae²: float # the current g_ae value (squared)
    logLVals: Tensor[float] # the logL values corresponding to `couplings`
    maxIdx: int # index of the maximum of the logL curve
    systematics: Systematics
    noiseFilter: NoiseFilter
    # additional fields for computation & input data storage
    rombergIntegrationDepth: int ## only for case of logLFullUncertain integration!
    filePath: string   ## The path to the data files
    files: seq[string] ## The data files we read

  ## For now a noise filter only defines a single set of pixels that are applied to
  ## all files in `fnames`. In the future we could generalize to specific sets of pixels
  ## for individual files.
  NoiseFilter = object
    pixels: seq[(int, int)] # the pixels to filter
    fnames: seq[string] # the filenames this filter should be applied to

proc pretty(s: Systematics): string =
  result = "("
  case s.uncertainty
  of ukCertain:       result.add "sigBack: (σ_s = σ_b = 0)"
  of ukUncertainSig:  result.add &"sigBack: (σ_s = {s.σs_sig}, σ_b = 0)"
  of ukUncertainBack: result.add &"sigBack: (σ_s = 0, σ_b = {s.σb_back})"
  of ukUncertain:     result.add &"sigBack: (σ_s = {s.σsb_sig}, σ_b = {s.σsb_back})"
  result.add ", "
  case s.uncertaintyPosition
  of puCertain:       result.add "(pos: σ_p = 0)"
  of puUncertain:     result.add &"(pos: σ_p = {s.σ_p})"
  result.add ")"

template uncertainty(ctx: Context): UncertaintyKind =
  ctx.systematics.uncertainty

template uncertaintyPosition(ctx: Context): PositionUncertaintyKind =
  ctx.systematics.uncertaintyPosition

template σs_sig(ctx: Context): float =
  doAssert ctx.uncertainty == ukUncertainSig
  ctx.systematics.σs_sig

template `σs_sig=`(ctx: Context, val: float) {.used.} =
  doAssert ctx.uncertainty == ukUncertainSig
  ctx.systematics.σs_sig = val

template σb_back(ctx: Context): float =
  doAssert ctx.uncertainty == ukUncertainBack
  ctx.systematics.σb_back

template `σs_back=`(ctx: Context, val: float) {.used.} =
  doAssert ctx.uncertainty == ukUncertainBack
  ctx.systematics.σs_sig = val

template σsb_sig(ctx: Context): float =
  doAssert ctx.uncertainty == ukUncertain
  ctx.systematics.σsb_sig

template `σsb_sig=`(ctx: Context, val: float) =
  doAssert ctx.uncertainty == ukUncertain
  ctx.systematics.σsb_sig = val

template σsb_back(ctx: Context): float =
  doAssert ctx.uncertainty == ukUncertain
  ctx.systematics.σsb_back

template `σsb_back=`(ctx: Context, val: float) =
  doAssert ctx.uncertainty == ukUncertain
  ctx.systematics.σsb_back = val

template σ_p(ctx: Context): float =
  doAssert ctx.uncertaintyPosition == puUncertain
  ctx.systematics.σ_p

template θ_x(ctx: Context): float =
  doAssert ctx.uncertaintyPosition == puUncertain
  ctx.systematics.θ_x

template `θ_x=`(ctx: Context, val: float) =
  ctx.systematics.θ_x = val

template θ_y(ctx: Context): float =
  doAssert ctx.uncertaintyPosition == puUncertain
  ctx.systematics.θ_y

template `θ_y=`(ctx: Context, val: float) =
  ctx.systematics.θ_y = val

## Logging helpers
proc info(logger: Logger, msgs: varargs[string, `$`]) =
  logger.log(lvlInfo, msgs)

import macros, std/genasts
proc toHeader(h, sep: string): string =
  result = repeat(sep, 15) & " " & h & " " & repeat(sep, 15)

proc infosImpl(log, header, prefix, sep, args: NimNode): NimNode =
  result = newStmtList()
  if header.kind == nnkStrLit and header.strVal.len > 0 or
     header.kind != nnkStrLit:
    let h = genAst(log, header, prefix, sep):
      log.info(prefix & toHeader(header, sep))
    result.add h
  for arg in args:
    let x = genAst(log, prefix, arg):
      log.info prefix & "\t" & arg
    result.add x

macro infos(log: Logger, header: string, args: untyped): untyped =
  result = infosImpl(log, header, newLit "", newLit "=", args)

proc infoHeader(log: Logger, line: string, prefix = "", sep = "=") =
  log.info(prefix & toHeader(line, sep))

macro infosNoHeader(log: Logger, args: untyped): untyped =
  result = infosImpl(log, newLit "", newLit "", newLit "=", args)

macro infosP(log: Logger, header, prefix, sep: string, args: untyped): untyped =
  result = infosImpl(log, header, prefix, sep, args)

## Clone
proc clone(t: Table[Candidate, keV⁻¹•cm⁻²]): Table[Candidate, keV⁻¹•cm⁻²] =
  result = initTable[Candidate, keV⁻¹•cm⁻²]()
  for key, val in t:
    result[key] = val

proc clone(it: Interpolation): Interpolation =
  result = Interpolation(kd: it.kd.clone(),
                         backCache: it.backCache.clone(),
                         radius: it.radius,
                         energyRange: it.energyRange,
                         nxy: it.nxy,
                         nE: it.nE, xyOffset: it.xyOffset,
                         eOffset: it.eOffset,
                         coords: it.coords,
                         energies: it.energies,
                         expCounts: it.expCounts.clone(),
                         zeroSig: it.zeroSig,
                         zeroBack: it.zeroBack,
                         zeroSigBack: it.zeroSigBack)

proc clone(ctx: Context): Context =
  result = Context(mcIdx: ctx.mcIdx,
                   axionModel: ctx.axionModel.clone(),
                   integralBase: ctx.integralBase,
                   axionSpl: ctx.axionSpl.clone(),
                   efficiencySpl: ctx.efficiencySpl.clone(),
                   raytraceSpl: ctx.raytraceSpl.clone(),
                   backgroundSpl: ctx.backgroundSpl.clone(),
                   backgroundCDF: ctx.backgroundCDF,
                   energyForBCDF: ctx.energyForBCDF,
                   totalBackgroundClusters: ctx.totalBackgroundClusters,
                   samplingKind: ctx.samplingKind,
                   couplingStep: ctx.couplingStep,
                   g_aγ²: ctx.g_aγ²,
                   g_ae²: ctx.g_ae²,
                   logLVals: ctx.logLVals.clone(),
                   maxIdx: ctx.maxIdx,
                   systematics: ctx.systematics)
  case ctx.samplingKind
  of skInterpBackground:
    result.interp = ctx.interp.clone()
  else: discard

converter toChipCoords(pos: tuple[x, y: float]): tuple[x, y: ChipCoord] =
  result = (x: ChipCoord(pos.x), y: ChipCoord(pos.y))

converter toChipCoords(pos: Option[tuple[x, y: float]]): Option[tuple[x, y: ChipCoord]] =
  if pos.isSome:
    let p = pos.get
    result = some((x: ChipCoord(p.x), y: ChipCoord(p.y)))

proc cdf(x: float, μ = 0.0, σ = 1.0): float = 0.5 * (1.0 + erf((x - μ) / (σ * sqrt(2.0))))
proc calcSigma95(): float =
  let res = block:
    var x = 0.0
    while cdf(x) < 0.95:
      x += 0.0001
    x
  result = res * res / 2.0

proc flatten(dfs: seq[DataFrame]): DataFrame =
  ## flatten a seq of DFs, which are identical by stacking them
  for df in dfs:
    result.add df.clone

proc filterNoisyPixels(df: DataFrame, noiseFilter: NoiseFilter): DataFrame =
  var xSet = initIntSet()
  var ySet = initIntSet()
  for p in noiseFilter.pixels:
    xSet.incl p[0]
    ySet.incl p[1]
  doAssert "centerX" in df and "centerY" in df, "centerX / centerY not found in input df. " & $df.getKeys()
  result = df.filter(f{not (toIdx(`centerX`) in xSet and
                            toIdx(`centerY`) in ySet)})

proc readFiles(path: string, s: seq[string], noiseFilter: NoiseFilter): DataFrame =
  var h5fs = newSeq[datatypes.H5File]()
  echo path
  echo s
  for fs in s:
    h5fs.add H5open(path / fs, "r")
  result = h5fs.mapIt(
    it.readDsets(likelihoodBase(), some((chip: 3, dsets: @["energyFromCharge", "centerX", "centerY"])))
    .rename(f{"Energy" <- "energyFromCharge"})
    .filterNoisyPixels(noiseFilter)
  ).flatten
  doAssert not result.isNil, "Our input data is nil. This should not happen!"
  echo "[INFO]: Read a total of ", result.len, " input clusters."
  ## NOTE: the energy cutoff used here does not matter much, because the background interpolation
  ## is of course energy dependent and only happens in an `EnergyRange` around the desired point.
  ## The candidates are drawn in a range defined by `EnergyCutoff`. The kd tree just has to be
  ## able to provide points for the interpolation up to the `EnergyCutoff`. That's why the
  ## `t.sum()` does not change if we change the energy filter here.
  result = result.filter(f{`Energy` < 12.0})
  for h in h5fs:
    discard h.close()

defUnit(keV⁻¹•cm⁻²•s⁻¹)
defUnit(keV⁻¹•m⁻²•yr⁻¹)
defUnit(cm⁻²)
defUnit(keV⁻¹•cm⁻²)
proc readAxModel(): DataFrame =
  let upperBin = 10.0
  proc convert(x: float): float =
    result = x.keV⁻¹•m⁻²•yr⁻¹.to(keV⁻¹•cm⁻²•s⁻¹).float
  result = readCsv("/home/basti/CastData/ExternCode/AxionElectronLimit/axion_diff_flux_gae_1e-13_gagamma_1e-12.csv")
    .mutate(f{"Energy / keV" ~ c"Energy / eV" / 1000.0},
            f{"Flux / keV⁻¹•cm⁻²•s⁻¹" ~ convert(idx("Flux / keV⁻¹ m⁻² yr⁻¹"))})
    .filter(f{float: c"Energy / keV" <= upperBin})

proc detectionEff(ctx: Context, energy: keV): UnitLess {.gcsafe.}

template toCDF(data: seq[float], isCumSum = false): untyped =
  ## Computes the CDF of binned data
  ## XXX: fix me!!
  var dataCdf = data
  if not isCumSum:
    seqmath.cumsum(dataCdf)
  let integral = dataCdf[^1]
  ## XXX: must not subtract baseline!
  let baseline = 0.0 # dataCdf[0]
  dataCdf.mapIt((it - baseline) / (integral - baseline))

proc unbinnedCdf[T: Tensor[float] | seq[float]](x: T): (Tensor[float], seq[float]) =
  ## Computes the CDF of unbinned data
  var cdf = newSeq[float](x.len)
  for i in 0 ..< x.len:
    cdf[i] = i.float / x.len.float
  result = (x.sorted, cdf)

proc setupBackgroundInterpolation(kd: KDTree[float],
                                  radius, sigma: float,
                                  energyRange: keV,
                                  backgroundTime, trackingTime: Hour,
                                  nxy, nE: int): Interpolation =
  ## Make sure to set the global variables (*ughhh!!!*)
  # set globals of interpolation, to make sure they really *do* have the same values
  Radius = radius # 33.3
  Sigma = sigma # 11.1
  EnergyRange = energyRange # 0.3.keV

  ## Need an offset to not start on edge, but rather within
  ## and stop half a step before
  let xyOffset = 14.0/(nxy).float / 2.0 ## XXX: fix this for real number ``within`` the chip
  ## XXX: should this be 10? Or 12? or what?
  ## Should not matter too much of course, as we lookup background rate *locally* also
  ## within energy!
  let Cutoff = 10.0
  let eOffset = Cutoff/(nE).float / 2.0

  let dist = (xyOffset * 2.0).mm
  let area = dist * dist # area of considered area
  echo area
  let ΔE = (eOffset * 2.0).keV
  echo ΔE
  let volume = area * ΔE
  echo volume

  var t = newTensor[float]([nxy, nxy, nE])
  let coords = linspace(0.0 + xyOffset, 14.0 - xyOffset, nxy)
  let energies = linspace(0.0 + eOffset, Cutoff - eOffset, nE)

  ## TODO: fully verify the sum of the tensor here. It seems like the sum is off a bit.
  ## Also: `correctEdgeCutoff` has a significant effect on the sum (which partially makes sense
  ## of course!), but the question is do we handle the "result" of having more candidates therefore
  ## correctly?
  ## In addition though: it seems to me like changing the energy cutoff of the input data
  ## (i.e. changing the total number of clusters) does not translate into a change of the
  ## `t.sum()`. But I think this is precisely due to our normalization here? As it uses
  ## its own `EnergyCutoff`. However: it should clearly increase the value `val` after
  ## `normalizeValue`!
  for yIdx in 0 ..< nxy:
    for xIdx in 0 ..< nxy:
      for iE, E in energies:
        let y = coords[yIdx]
        let x = coords[xIdx]
        let tup = kd.query_ball_point([x.toIdx.float, y.toIdx.float, E].toTensor, Radius, metric = CustomMetric)
        let val = compValue(tup)
          .correctEdgeCutoff(Radius, x.toIdx, y.toIdx)
          .normalizeValue(Radius, EnergyRange, backgroundTime)
        let valCount = val * volume * trackingTime.to(Second)
        #echo val, " as counts: ", valCount, " at ", x, " / ", y, " E = ", E
        t[yIdx, xIdx, iE] = valCount
  echo "[INFO] Sum of background interpolation tensor: ", t.sum()
  result = Interpolation(kd: kd, # kd storing clusters
                         nxy: nxy, nE: nE, # grid definiton variables for sampling
                         radius: radius, sigma: sigma, energyRange: energyRange, # parameters for weighing / search range
                         backgroundTime: backgroundTime,
                         trackingTime: trackingTime,
                         coords: coords,
                         energies: energies,
                         xyOffset: xyOffset, eOffset: eOffset,
                         expCounts: t)

proc initSystematics(
  σ_sig = 0.0, σ_back = 0.0, σ_p = 0.0,
  uncertainty = none[UncertaintyKind](),
  uncertaintyPos = none[PositionUncertaintyKind]()
     ): Systematics =
  ## Constructs the correct `Systematics` given the desired values.
  let uncertain = if uncertainty.isSome: uncertainty.get
                  elif σ_sig == 0.0 and σ_back == 0.0: ukCertain
                  elif σ_sig == 0.0: ukUncertainBack
                  elif σ_back == 0.0: ukUncertainSig
                  else: ukUncertain
  let uncertainPos = if uncertaintyPos.isSome: uncertaintyPos.get
                     elif σ_p == 0.0: puCertain
                     else: puUncertain
  result = Systematics(uncertainty: uncertain,
                       uncertaintyPosition: uncertainPos)
  ## Set fields for uncertainties
  case uncertain
  of ukUncertainSig:
    result.σs_sig = σ_sig
  of ukUncertainBack:
    result.σb_back = σ_back
  of ukUncertain:
    result.σsb_sig = σ_sig
    result.σsb_back = σ_back
  else: discard # nothing to do

  case uncertainPos
  of puUncertain:
    result.σ_p = σ_p
  else: discard # nothing to do

proc initNoiseFilter(yearFiles: seq[(int, string)]): NoiseFilter =
  ## Argument contains the year (0) of the data file (1). The years for which
  ## the filter will apply are hardcoded here for the time being.
  ## XXX: only apply these to 2017 files & correct sensitive area!
  const noisyPixels = [
    (2017, [
      (64, 109),
      (64, 110),
      (67, 112),
      (65, 108),
      (66, 108),
      (67, 108),
      (65, 109),
      (66, 109),
      (67, 109),
      (68, 109),
      (65, 110),
      (66, 110),
      (67, 110),
      (65, 111),
      (66, 111),
      (67, 111),
      (68, 110),
      (68, 109),
      (68, 111),
      (68, 108),
      (67, 107),
      (66, 111),
      (69, 110)
    ])
  ]
  doAssert noisyPixels.len == 1, "For now only single set of noisy pixels implemented."
  for (year, pixels) in noisyPixels:
    result = NoiseFilter(pixels: @pixels,
                         fnames: yearFiles.filterIt(it[0] == year).mapIt(it[1]))

proc initContext(path: string, yearFiles: seq[(int, string)],
                 useConstantBackground: bool, # decides whether to use background interpolation or not
                 radius, sigma: float, energyRange: keV, nxy, nE: int,
                 backgroundTime, trackingTime: Hour,
                 windowRotation = 30.°,
                 σ_sig = 0.0, σ_back = 0.0, # depending on which `σ` is given as > 0, determines uncertainty
                 σ_p = 0.0,
                 rombergIntegrationDepth = 5
                ): Context =
  let samplingKind = if useConstantBackground: skConstBackground else: skInterpBackground

  let axData = readAxModel()
  ## TODO: use linear interpolator to avoid going to negative?
  let axSpl = newCubicSpline(axData["Energy / keV", float].toSeq1D,
                             axData["Flux / keV⁻¹•cm⁻²•s⁻¹", float].toSeq1D)

  let combEffDf = readCsv("/home/basti/org/resources/combined_detector_efficiencies.csv")
  let effSpl = newCubicSpline(combEffDf["Energy [keV]", float].toSeq1D,
                              #combEffDf["Efficiency", float].toSeq1D)
                              combEffDf["Eff • ε • LLNL", float].toSeq1D) # effective area included in raytracer

  let raySpl = block:
    #let hmap = readCsv("/home/basti/org/resources/axion_image_heatmap_2017.csv")
    #let hmap = readCsv("/home/basti/org/resources/axion_image_30deg_1485mm.csv")
    let hmap = readCsv("/home/basti/org/resources/axion_image_no_window_1470mm_plus_12_2mm_updated_cone_tracing.csv")
    ggplot(hmap, aes("x", "y", fill = "z")) +
      geom_raster() + ggsave("/tmp/raster_what_old.pdf")
    var t = zeros[float]([256, 256])

    let area = 1.4.cm * 1.4.cm
    let pixels = 256 * 256
    let pixPerArea = pixels / area

    let zSum = hmap["z", float].sum
    for idx in 0 ..< hmap.len:
      let x = hmap["x", int][idx]
      let y = hmap["y", int][idx]
      #echo "X ", x, " and ", y
      let z = hmap["z", float][idx]
      t[x, y] = (z / zSum * pixPerArea).float #zMax / 784.597 # / zSum # TODO: add telescope efficiency abs. * 0.98
    newBilinearSpline(t, (0.0, 255.0), (0.0, 255.0)) # bicubic produces negative values!

  let files = yearFiles.mapIt(it[1])
  let noiseFilter = initNoiseFilter(yearFiles)
  var df = readFiles(path, files, noiseFilter)
  let kdeSpl = block:
    var dfLoc = df.toKDE(true)
    newCubicSpline(dfLoc["Energy", float].toSeq1D, dfLoc["KDE", float].toSeq1D)
  let backgroundInterp = toNearestNeighborTree(df)
  let energies = linspace(0.071, 9.999, 10000).mapIt(it) # cut to range valid in interpolation
  let backgroundCdf = energies.mapIt(kdeSpl.eval(it)).toCDF()

  result = Context(samplingKind: samplingKind,
                   axionModel: axData,
                   axionSpl: axSpl,
                   windowRotation: windowRotation,
                   efficiencySpl: effSpl,
                   raytraceSpl: raySpl,
                   backgroundSpl: kdeSpl,
                   backgroundDf: df,
                   backgroundCDF: backgroundCdf,
                   energyForBCDF: energies,
                   totalBackgroundClusters: df.len,
                   totalBackgroundTime: backgroundTime,
                   totalTrackingTime: trackingTime,
                   g_aγ²: 1e-12 * 1e-12, ## reference axion photon coupling
                   systematics: initSystematics(σ_sig, σ_back, σ_p),
                   noiseFilter: noiseFilter,
                   rombergIntegrationDepth: rombergIntegrationDepth,
                   filePath: path,
                   files: files)
  let ctx = result # XXX: hack to workaround bug in formula macro due to `result` name!!!
  let axModel = axData
    .mutate(f{"Flux" ~ idx("Flux / keV⁻¹•cm⁻²•s⁻¹") * detectionEff(ctx, idx("Energy / keV").keV) })
  echo axModel
  let integralBase = simpson(axModel["Flux", float].toSeq1D,
                             axModel["Energy / keV", float].toSeq1D)
  result.integralBase = integralBase

  ## Set fields for interpolation
  if not useConstantBackground:
    ## initialize the variables needed for the interpolation
    let interp = setupBackgroundInterpolation(
      backgroundInterp, radius, sigma, energyRange,
      backgroundTime, trackingTime,
      nxy, nE
    )
    result.interp = interp

proc rescale(x: float, new: float): float =
  ## `new` must already be squared!
  let old = 1e-13 # initial value is always 1e-13
  result = x * new / (old * old)

proc rescale(s: seq[float], g_ae²: float): seq[float] =
  ## rescaling version, which takes a `new` squared coupling constant
  ## to allow for negative squares
  result = newSeq[float](s.len)
  for i, el in s:
    result[i] = el.rescale(g_ae²)

proc plotCandidates(cands: seq[Candidate],
                    outfile = "/tmp/candidates.pdf",
                    title = "",
                    topMargin = 1.0
                   ) =
  let dfC = toDf({ "x" : cands.mapIt(it.pos.x.float),
                       "y" : cands.mapIt(it.pos.y.float),
                       "E" : cands.mapIt(it.energy.float)})
  ggplot(dfC, aes("x", "y", color = "E")) +
    geom_point() +
    ggtitle(title) +
    margin(top = topMargin) +
    ggsave(outfile)

import random / mersenne
import alea / [core, rng, gauss, poisson]
proc drawCandidates(ctx: Context,
                    rnd: var Random,
                    posOverride = none(tuple[x, y: ChipCoord]),
                    toPlot: static bool = false): seq[Candidate] {.gcsafe.} =
  ## draws a number of random candidates from the background sample
  ## using the ratio of tracking to background ~19.5
  # 1. clear the background cache of context, if we're using interpolation
  if ctx.samplingKind == skInterpBackground:
    ctx.interp.backCache.clear()
  when false:
    var df = df.filter(f{`Energy` <= 10.0}) # filter to < 10 keV for interpolation
      .mutate(f{float: "Random" ~ rand(1.0)})
      .filter(f{`Random` <= 1.0 / TrackingBackgroundRatio}) # take the 1/19.5 subset

  case ctx.samplingKind
  of skConstBackground:
    let uni = uniform(0.0, 1.0)
    let goldUni = uniform(4.5, 9.5)
    # 0. create Poisson sampler based on expected number of clusters (λ = tracking cluster expectation)
    let pois = poisson(ctx.totalBackgroundClusters / TrackingBackgroundRatio)
    for i in 0 ..< rnd.sample(pois).int:
      # 1. draw energy based on background CDF
      let energy = ctx.energyForBCDF[ctx.backgroundCDF.lowerBound(rnd.sample(uni))].keV
      # 2. draw position within region of interest
      let pos = block:
        if posOverride.isSome:
          posOverride.get
        else:
          (x: ChipCoord(rnd.sample(goldUni)), y: ChipCoord(rnd.sample(goldUni)))
      result.add Candidate(energy: energy, pos: pos)
  of skInterpBackground:
    var pois = poisson(1.0)       ## Will be adjusted for each grid point
    var uniXY = uniform(0.0, 0.0) ## Will be adjusted for each grid point
    var uniE = uniform(0.0, 0.0)
    result = newSeqOfCap[Candidate](10000)
    # 1. iterate over every position of the background tensor
    for iE in 0 ..< ctx.interp.energies.len:
      for ix in 0 ..< ctx.interp.coords.len:
        for iy in 0 ..< ctx.interp.coords.len:
          # 2. draw form a poisson with mean = the value at that tensor position (is normalized to expected counts)
          pois.l = ctx.interp.expCounts[iy, ix, iE]
          for _ in 0 ..< rnd.sample(pois).int:
            # 3. the resulting number of candidates will be created
            # 3a. for each candidate, smear the position & energy within the volume of the grid cell
            uniE.a = ctx.interp.energies[iE] - ctx.interp.eOffset
            uniE.b = ctx.interp.energies[iE] + ctx.interp.eOffset
            if posOverride.isSome:
              let pos = posOverride.get
              result.add Candidate(energy: rnd.sample(uniE).keV, pos: pos)
            else:
              uniXY.a = ctx.interp.coords[ix] - ctx.interp.xyOffset
              uniXY.b = ctx.interp.coords[ix] + ctx.interp.xyOffset
              let xpos = clamp(rnd.sample(uniXY), 0.0, 14.0)
              uniXY.a = ctx.interp.coords[iy] - ctx.interp.xyOffset
              uniXY.b = ctx.interp.coords[iy] + ctx.interp.xyOffset
              let ypos = clamp(rnd.sample(uniXY), 0.0, 14.0)
              result.add Candidate(energy: rnd.sample(uniE).keV, pos: (x: ChipCoord(xpos), y: ChipCoord(ypos)))
  when false: #toPlot:
    plotCandidates(result)

defUnit(cm²)
defUnit(keV⁻¹)
proc hitsStrongback(y: float): bool =
  ## For a given y position in `mm` in a coordinate system in which the strongback
  ## is parallel to the x axis, returns whether the coordinate is on top of the
  ## strongback of the window (with the layout used at CAST in 2017/18).
  ##
  ## The input argument can be rotated to the correct frame using `invertWindowRotation`.
  const
    stripDistWindow = 2.3  #mm
    stripWidthWindow = 0.5 #mm
  result = abs(y) > stripDistWindow / 2.0 and
    abs(y) < stripDistWindow / 2.0 + stripWidthWindow or
    abs(y) > 1.5 * stripDistWindow + stripWidthWindow and
    abs(y) < 1.5 * stripDistWindow + 2.0 * stripWidthWindow

proc invertWindowRotation(ctx: Context, x, y: float): float =
  ## Rotates the coordinates into a rotated system such that the strongback
  ## lies parallel to the x axis. This is to simplify the detection of whether
  ## a candidate hits the strongback.
  ##
  ## The rotated `y` coordinate is returned as an input to `hitsStrongback`.
  let rot = ctx.windowRotation
  # subtract 7.0 to move position from (0, 14) to (-7, 7)
  let (xp, yp) = (x - 7.0, y - 7.0)
  result = yp * cos(-rot.to(Radian)) - xp * sin(-rot.to(Radian))

proc axionFlux(ctx: Context, energy: keV): keV⁻¹ =
  ## The absolute differential flux coming from the sun (depends on g_ae)
  ## per keV (i.e. all that is collected in the area of the cold bore ⇔ by the
  ## telescope aperture within the tracking time)
  let areaBore = π * (2.15 * 2.15).cm² # area of bore in cm²
  if energy < 0.001.keV or energy > 10.0.keV: return 0.0.keV⁻¹
  result = ctx.axionSpl.eval(energy.float).rescale(ctx.g_ae²).keV⁻¹•cm⁻²•s⁻¹ * # missing keV⁻¹
    areaBore *
    ctx.totalTrackingTime.to(s)

proc detectionEff(ctx: Context, energy: keV): UnitLess {.gcsafe.} =
  # window + gas
  if energy < 0.001.keV or energy > 10.0.keV: return 0.0
  result = ctx.efficiencySpl.eval(energy.float)

proc raytracing(ctx: Context, pos: tuple[x, y: float], ignoreWindow: static bool = false): cm⁻² =
  ## returns the 'flux likelihood' at the given point
  ##
  ## Units of return value mean "percentage of total flux per cm²"
  var x = pos.x
  var y = pos.y
  when not ignoreWindow:
    if ctx.invertWindowRotation(x, y).hitsStrongback():
      return 0.cm⁻²
  if ctx.uncertaintyPosition == puUncertain:
    ## XXX: investigate me! The old code does not make sense I think,
    ## but I'm not sure if this is correct now. Start from analytical
    ## derivation again.
    x = pos.x + ctx.θ_x * 7.0 #* (1.0 + ctx.θ_x)
    y = pos.y + ctx.θ_y * 7.0 #* (1.0 + ctx.θ_y)
  if x notin 0.0 .. 14.0 or
     y notin 0.0 .. 14.0:
    return 0.cm⁻²
  # else compute the raytracing argument data
  ## XXX: should this use toIdx and thus 256 and clamp? check that
  let px = x / 14.0 * 255.0
  let py = y / 14.0 * 255.0
  result = ctx.raytraceSpl.eval(px, py).cm⁻²

proc detectionEfficiency(ctx: Context, energy: keV, pos: tuple[x, y: float]): cm⁻² =
  ## the total detection efficiency
  result = ctx.detectionEff(energy) * ctx.raytracing(pos)

func conversionProbability(): UnitLess =
  ## the conversion probability in the CAST magnet (depends on g_aγ)
  ## simplified vacuum conversion prob. for small masses
  let B = 9.0.T
  let L = 9.26.m
  let g_aγ = 1e-12.GeV⁻¹ # ``must`` be same as reference in Context
  result = pow( (g_aγ * B.toNaturalUnit * L.toNaturalUnit / 2.0), 2.0 )

proc expectedSignal(ctx: Context, energy: keV, pos: tuple[x, y: float]): keV⁻¹•cm⁻² =
  ## TODO: conversion to detection area??
  result = ctx.axionFlux(energy) * conversionProbability() * ctx.detectionEfficiency(energy, pos)

proc toIntegrated(r: keV⁻¹•cm⁻²•s⁻¹, trackingTime: Hour): keV⁻¹•cm⁻² =
  ## Turns the background rate into an integrated rate over the tracking time
  #let area = 1.4.cm * 1.4.cm
  let t = trackingTime.to(Second)
  result = r * t

proc evalInterp(interp: var Interpolation, c: Candidate): keV⁻¹•cm⁻² =
  #echo "POSITION ", pos.x, " and ", pos.y
  #echo "INTERP: ", pos.x, " and ", pos.y
  ## NOTE: `pos.x/y` needs to be given as value [0, 255] to kd tree, but we get [0, 14]!
  template computeBackground(): untyped {.dirty.} =
    let px = c.pos.x.toIdx
    let py = c.pos.y.toIdx
    interp.kd.query_ball_point([px.float, py.float, c.energy.float].toTensor,
                             radius = interp.radius,
                             metric = CustomMetric)
      .compValue()
      .correctEdgeCutoff(interp.radius, px, py) # this should be correct
      .normalizeValue(interp.radius, interp.energyRange, interp.backgroundTime)
      .toIntegrated(interp.trackingTime)
  ## Either get the cached value or compute the value and place it into the table
  result = interp.backCache.getOrDefault(c, -Inf.keV⁻¹•cm⁻²)
  if classify(result.float) == fcNegInf:
    result = computeBackground()
    interp.backCache[c] = result

proc background(ctx: Context, c: Candidate): keV⁻¹•cm⁻² =
  if ctx.samplingKind == skConstBackground:
    result = ctx.backgroundSpl.eval(c.energy.float).keV⁻¹•cm⁻²
  else:
    result = ctx.interp.evalInterp(c)

proc background(ctx: Context, energy: keV, pos: tuple[x, y: ChipCoord]): keV⁻¹•cm⁻² =
  ## Convenience wrapper around background for the case of calling it with args instead
  ## of a candidate
  result = ctx.background(Candidate(energy: energy, pos: pos))

proc rate(ctx: Context, c: Candidate): float =
  let b = ctx.background(c)
  let s = ctx.expectedSignal(c.energy, c.pos)
  if s == 0.0.keV⁻¹•cm⁻² and b == 0.0.keV⁻¹•cm⁻²:
    if ctx.samplingKind == skInterpBackground:
      inc ctx.interp.zeroSigBack
    result = 1.0
  elif b == 0.0.keV⁻¹•cm⁻²:
    if ctx.samplingKind == skInterpBackground:
      inc ctx.interp.zeroBack
    result = 1.0
  elif s == 0.0.keV⁻¹•cm⁻²:
    if ctx.samplingKind == skInterpBackground:
      inc ctx.interp.zeroSig
    result = 1.0
  else: result = (1.0 + s / b)

defUnit(cm⁻²•s⁻¹)
proc expRate(ctx: Context): UnitLess =
  ## TODO: only count the fraction of evnts expected in gold region! Extract inforamtion
  ## from heatmap by looking for ratio of sum inside gold / sum outside gold
  let areaBore = π * (2.15 * 2.15).cm²

  let integral = ctx.integralBase.rescale(ctx.g_ae²)
  result = integral.cm⁻²•s⁻¹ * areaBore * ctx.totalTrackingTime.to(s) * conversionProbability()

proc plotRaytracingImage(ctx: Context, log: Logger,
                         outname = "/tmp/axion_image_limit_calc.pdf",
                         title = "Axion image as used in limit calculation",
                         ignoreWindow: static bool = false) =
  ## generates a visualization of the raytracing interpolator, or more specifically
  ## the `raytracing` procedure.
  let coords = linspace(0.0, 14.0, 256)
  var xs = newSeq[float]()
  var ys = newSeq[float]()
  var zs = newSeq[float]()
  for x in coords:
    for y in coords:
      xs.add x
      ys.add y
      zs.add ctx.raytracing((x: x, y: y), ignoreWindow).float
  let df = toDf(xs, ys, zs)
  var customInferno = inferno()
  customInferno.colors[0] = 0 # transparent

  let pixelsPerSqCm = 256^2 / (1.4.cm * 1.4.cm)
  log.infosNoHeader:
    &"Raytracing sanity check for: ignoreWindow = {ignoreWindow}, θ_x = θ_y = {ctx.θ_x}"
    &"Sum of raytracing contributions over the whole chip: {zs.sum.cm⁻²}"
    &"\tcorresponds to number of pixels per cm⁻²"
    &"Raytracing contributions over the whole chip normalized to chip area: {zs.sum.cm⁻² / pixelsPerSqCm}"
    &"\twhere the normalization is {pixelsPerSqCm}, the number of pixel per cm²"
    &"\tmeaning the raytracing contribution is normalized."
    &"At a single pixel position the value thus corresponds to the amount of flux over unity one"
    &"\twould receive if taken over whole chip."
    &"Saving plot: {outname}"

  ggplot(df, aes("xs", "ys", fill = "zs")) +
    geom_raster() +
    scale_fill_gradient(customInferno) +
    ggtitle(title) +
    ggsave(outname)

proc resetZeroCounters(ctx: Context) =
  ## sets the `zero*` fields of the interpolator to 0
  ctx.interp.zeroSig = 0
  ctx.interp.zeroBack = 0
  ctx.interp.zeroSigBack = 0

proc printZeroCounters(ctx: Context, numCand: int) {.used.} =
  echo "================================================================================"
  echo "g_aγ² = ", ctx.g_aγ²
  echo "g_ae² = ", ctx.g_ae²
  echo "Number of candidates: ", numCand
  echo "Number of zero signal candidates:     ", ctx.interp.zeroSig
  echo "Number of zero background candidates: ", ctx.interp.zeroBack
  echo "Number of zero sig & back candidates: ", ctx.interp.zeroSigBack

template L(s, s_c, b_c, θ_s, σ_s, θ_b, σ_b: untyped,
           θ_x = 0.0, σ_xp = 0.0, θ_y = 0.0, σ_yp = 0.0): untyped =
  ## `s`, `s_i` and `b_i` may be modified / unmodified depending on which uncertainty
  ## is selected
  ##: XXX: better to do exp( ln( ... ) ), or exp() * exp() * exp() ?
  result = exp(-s)
  #echo "-s ", s, " result ", result
  if σ_s > 0.0:
    result *= exp(-pow(θ_s / (sqrt(2.0) * σ_s), 2)) ## FIXME the normalization of denominator is wrong missing √2
  elif σ_s == 0.0 and θ_s != 0.0:
    result = 0
  if σ_b > 0.0:
    result *= exp(-pow(θ_b / (sqrt(2.0) * σ_b), 2))
  elif σ_b == 0.0 and θ_b != 0.0:
    result = 0
  if σ_xp > 0.0 and σ_yp > 0.0:
    result *= exp(-pow(θ_x / (sqrt(2.0) * σ_xp), 2)) * exp(-pow(θ_y / (sqrt(2.0) * σ_yp), 2))

  #echo "current result ", result
  for (s_i {.inject.}, b_i {.inject.}) in cSigBack:
    ## XXX: how to deal with `s_c` or `b_c` negative? Results in negative arg to log if `s/b` is smaller
    ## than -1. In product this is not an issue. But well...
    if b_c.float != 0.0:
      #echo "result at b_i ", b_i, " res = ", result
      result *= (1 + s_c / b_c) # log-normal (but wrong): / (b_c * σ_b * b_i)
  #if true: quit()
  #echo "Result exp is ", result, " for θ_s = ", θ_s, ", θ_b = ", θ_b
  if result.isNaN:
    echo "WARNING WARNING NAN"
    #quit("quitting from L")

proc logLUncertainSig(ctx: Context, candidates: seq[Candidate]): float =
  if ctx.samplingKind == skInterpBackground:
    resetZeroCounters(ctx)
  ## integration of L over `θ_s` using the current parameters for `s`, `b_i`, `s_i`
  ## is equivalent to integration & then evaluating integral at position of these params
  let s_tot = expRate(ctx)
  let σ_s = ctx.σs_sig

  var cSigBack = newSeq[(float, float)](candidates.len)
  for i, c in candidates:
    cSigBack[i] = (ctx.expectedSignal(c.energy, c.pos).float,
                   ctx.background(c.energy, c.pos).float)
  proc likelihood(θ_s: float, nc: NumContext[float, float]): float =
    L(s_tot * (1 + θ_s),
      s_i * (1 + θ_s),
      b_i,
      θ_s, σ_s,
      0.0, 0.0)
  if σ_s > 0.0:
    let res = adaptiveGauss(likelihood, -10, 10)
    #echo "Integration result: ", res, ", ln(res) = ", ln(res), " for ", ctx.g_ae², " compare ", logLCertain(ctx, candidates)
    if res.isNaN:
      echo "CSigBack: ", cSigBack
      var f = open("/tmp/bad_candidates.txt", fmWrite)
      f.write("E, x, y\n")
      for cnd in candidates:
        f.write(&"{cnd.energy.float},{cnd.pos.x},{cnd.pos.y}\n")
      f.close()
      #quit()
      return Inf
    result = res
  else:
    L(s_tot, s_i, b_i, 0.0, 0.0, 0.0, 0.0)
    result = result

proc logLUncertainBack(ctx: Context, candidates: seq[Candidate]): float =
  if ctx.samplingKind == skInterpBackground:
    resetZeroCounters(ctx)

  ## integration of L over `θ_b` using the current parameters for `s`, `b_i`, `s_i`
  ## is equivalent to integration & then evaluating integral at position of these params
  let s_tot = expRate(ctx)
  let σ_b = ctx.σb_back
  var cSigBack = newSeq[(float, float)](candidates.len)
  for i, c in candidates:
    cSigBack[i] = (ctx.expectedSignal(c.energy, c.pos).float,
                   ctx.background(c.energy, c.pos).float)

  proc likelihood(θ_b: float, nc: NumContext[float, float]): float =
    L(s_tot,
      s_i,
      b_i * (1 + θ_b), # log-normal (but wrong): exp(b_i * (1 + θ_b)),
      0.0, 0.0,
      θ_b, σ_b)
  ## Mark the point `-1` as a difficult point, so that it's not evaluated. We do not care
  ## about the singularity at that point for the integration
  let res = adaptiveGauss(likelihood, -0.80, 10.0) #, initialPoints = @[-1.0])
  #echo "Integration result: ", res, ", ln(res) = ", ln(res), " for ", ctx.g_ae² #, " compare ", logLCertain(ctx, candidates)
  if res.isNaN:
    quit()

  result = res

proc logLUncertain(ctx: Context, candidates: seq[Candidate]): float =
  if ctx.samplingKind == skInterpBackground:
    resetZeroCounters(ctx)
  ## integration of L over `θ_b` using the current parameters for `s`, `b_i`, `s_i`
  ## is equivalent to integration & then evaluating integral at position of these params
  let s_tot = expRate(ctx)
  let σ_b = ctx.σsb_back
  let σ_s = ctx.σsb_sig
  var cSigBack = newSeq[(float, float)](candidates.len)
  for i, c in candidates:
    cSigBack[i] = (ctx.expectedSignal(c.energy, c.pos).float,
                   ctx.background(c.energy, c.pos).float)

  var count = 0
  proc likeBack(θ_b: float, nc: NumContext[float, float]): float =
    proc likeSig(θ_s: float, nc: NumContext[float, float]): float =
      L(s_tot * (1 + θ_s),
        s_i * (1 + θ_s),
        b_i * (1 + θ_b),
        θ_s, σ_s,
        θ_b, σ_b)
    result = adaptiveGauss(likeSig, -1.0, 2.0)
    #echo "Result of inner integral: ", result, " for θ_b = ", θ_b, " at call ", count
    inc count
  ## There is a singularity at `-1`. Everything smaller is irrelevant and the singularity is
  ## unphysical for us. Start above that.
  let res = adaptiveGauss(likeBack, -0.80, 1.0, maxintervals = 9999) #, initialPoints = @[-1.0])
  #echo "Integration result: ", res, ", ln(res) = ", ln(res), " for ", ctx.g_ae², " compare ", logLCertain(ctx, candidates)
  if res.isNaN:
    quit()

  result = res

proc logLPosUncertain(ctx: Context, candidates: seq[Candidate]): float =
  if ctx.samplingKind == skInterpBackground:
    resetZeroCounters(ctx)
  ## integration of L over `θ_b` using the current parameters for `s`, `b_i`, `s_i`
  ## is equivalent to integration & then evaluating integral at position of these params
  var cSigBack = newSeq[(float, float)](candidates.len)
  let SQRT2 = sqrt(2.0)
  let σ_p = ctx.σ_p
  let s_tot = expRate(ctx)
  for i, c in candidates:
    let sig = ctx.detectionEff(c.energy) * ctx.axionFlux(c.energy) * conversionProbability()
    cSigBack[i] = (sig.float,
                   ctx.background(c.energy, c.pos).float)
  proc likeX(θ_x: float, nc: NumContext[float, float]): float =
    ctx.θ_x = θ_x
    proc likeY(θ_y: float, nc: NumContext[float, float]): float =
      ctx.θ_y = θ_y
      let P1 = exp(-s_tot)
      let P2 = exp(-pow(θ_x / (SQRT2 * σ_p), 2)) * exp(-pow(θ_y / (SQRT2 * σ_p), 2))
      var P3 = 1.0
      for i in 0 ..< cSigBack.len:
        let (s_init, b_c) = cSigBack[i]
        if b_c.float != 0.0:
          let s_c = (s_init * ctx.raytracing(candidates[i].pos)).float
          P3 *= (1 + s_c / b_c)
      result = 1.0
      when true:
        result *= P1
      when true:
        result *= P2
      when true:
        result *= P3
    result = romberg(likeY, -1.0, 1.0, depth = 6)
  result = romberg(likeX, -1.0, 1.0, depth = 6)
  #  result = simpson(likeY, -1.0, 1.0, N = 100)#, N = 500)
  #result = ln(simpson(likeX, -1.0, 1.0, N = 100))#, N = 500))

proc logLFullUncertain(ctx: Context, candidates: seq[Candidate]): float =
  if ctx.samplingKind == skInterpBackground:
    resetZeroCounters(ctx)
  var cSigBack = newSeq[(float, float)](candidates.len)
  let SQRT2 = sqrt(2.0)
  let σ_p = ctx.σ_p
  let s_tot = expRate(ctx)
  let σ_b = ctx.σsb_back
  let σ_s = ctx.σsb_sig
  for i, c in candidates:
    let sig = ctx.detectionEff(c.energy) * ctx.axionFlux(c.energy) * conversionProbability()
    cSigBack[i] = (sig.float,
                   ctx.background(c.energy, c.pos).float)
  echo "Romberg integration for ", ctx.g_ae²
  proc likeX(θ_x: float, nc: NumContext[float, float]): float =
    ctx.θ_x = θ_x
    proc likeY(θ_y: float, nc: NumContext[float, float]): float =
      ctx.θ_y = θ_y
      proc likeSig(θ_s: float, nc: NumContext[float, float]): float =
        proc likeBack(θ_b: float, nc: NumContext[float, float]): float =
          let s_tot_p = s_tot * (1 + θ_s)
          let P1 = exp(-s_tot_p)
          let P2 = exp(-pow(θ_x / (SQRT2 * σ_p), 2)) * exp(-pow(θ_y / (SQRT2 * σ_p), 2)) *
                   exp(-pow(θ_s / (SQRT2 * σ_s), 2)) * exp(-pow(θ_b / (SQRT2 * σ_b), 2))
          var P3 = 1.0
          for i in 0 ..< cSigBack.len:
            let (s_init, b_i) = cSigBack[i]
            let s_i = s_init * (1 + θ_s)
            let b_c = b_i * (1 + θ_b)
            if b_c.float != 0.0:
              let s_c = (s_i * ctx.raytracing(candidates[i].pos)).float
              P3 *= (1 + s_c / b_c)
          #echo P1, " ", P2, " ", P3
          result = 1.0
          when true:
            result *= P1
          when true:
            result *= P2
          when true:
            result *= P3
        result = romberg(likeBack, -0.8, 2.0, depth = ctx.rombergIntegrationDepth) #adaptiveGauss(likeBack, -0.8, 2.0) #, depth = 6)
      result = romberg(likeSig, -2.0, 2.0, depth = ctx.rombergIntegrationDepth)
    result = romberg(likeY, -1.0, 1.0, depth = ctx.rombergIntegrationDepth)
  result = romberg(likeX, -1.0, 1.0, depth = ctx.rombergIntegrationDepth)
  #result = ln( res )
  if result.isNaN:
    echo "!!!"
    if true: quit()
  #
  #      result = trapz(likeBack, -0.8, 2.0, N = 30)#, depth = 2)
  #    result = trapz(likeSig, -2.0, 2.0, N = 30)# , depth = 2)
  #  result = romberg(likeY, -1.0, 1.0, depth = 3)
  #result = ln(romberg(likeX, -1.0, 1.0, depth = 3))

proc logLCertain(ctx: Context, candidates: seq[Candidate]): float =
  if ctx.samplingKind == skInterpBackground:
    resetZeroCounters(ctx)

  when true:
    result = -expRate(ctx)# * 0.002
    for c in candidates:
      let rt = ctx.rate(c)
      #echo "PURE RATE ", rt, " and ln ", ln(rt), " at position ", c.pos, " at g_ae ", ctx.g_ae², " result: ", result
      result += ln(rt)
      #if rt > 0.0:
  result = exp(result)

proc logL(ctx: Context, candidates: seq[Candidate]): float =
  if ctx.uncertaintyPosition == puCertain:
    case ctx.uncertainty
    of ukCertain:       result = logLCertain(ctx, candidates)
    of ukUncertainSig:  result = logLUncertainSig(ctx, candidates)
    of ukUncertainBack: result = logLUncertainBack(ctx, candidates)
    of ukUncertain:     result = logLUncertain(ctx, candidates)
  else:
    case ctx.uncertainty
    of ukCertain: result = logLPosUncertain(ctx, candidates)
    of ukUncertain: result = logLFullUncertain(ctx, candidates)
    else: doAssert false, "Not implemented mixed uncertainties w/o all"

template evalAt(ctx: Context, cands: seq[Candidate], val: untyped): untyped =
  ctx.g_ae² = val
  ctx.logL(cands)

type
  Likelihood = object
    coupling: float
    computed: bool # whether L has been computed
    L: float

  LimitHelper = object
    ctx: Context # storing a ref obj of the context
    cands: seq[Candidate]
    Ls: SortedSeq[Likelihood]
    cdf: seq[float] # CDF based on couplings & L in `Ls`
    deriv: seq[float] # 2nd 'derivative' (sort of) of CDF to check where to insert more points
    dy: float # relative value need larger to compute more points in CDF tail
    dDeriv: float # relative value needed to compute more points in derivative

proc `<`(l1, l2: Likelihood): bool =
  result = l1.coupling < l2.coupling

proc `==`(l1, l2: Likelihood): bool = l1.coupling == l2.coupling

proc cumSumUnequal(y, x: seq[float]): seq[float] =
  result = newSeq[float](y.len)
  doAssert x.len > 1
  var dx = x[1] - x[0]
  var cum = y[0] * dx # 0.0 #y[0] * dx
  for i in 0 ..< y.len:
    if i > 0:
      dx = x[i] - x[i-1]
      cum += y[i] * dx
    result[i] = cum # (cum - result[i]) * dx + result[i]

proc cdfUnequal(y, x: seq[float]): seq[float] =
  let cumS = cumSumUnequal(y, x)
  let integral = cumS[^1]
  ## XXX: must not subtract baseline!
  let baseline = 0.0 # cumS[0]
  doAssert integral != baseline, "what? " & $cumS
  result = cumS.mapIt((it - baseline) / (integral - baseline))

proc couplings(lh: LimitHelper): seq[float] =
  result = newSeq[float](lh.Ls.len)
  for i in 0 ..< lh.Ls.len:
    result[i] = lh.Ls[i].coupling

proc likelihoods(lh: LimitHelper): seq[float] =
  result = newSeq[float](lh.Ls.len)
  for i in 0 ..< lh.Ls.len:
    assert lh.Ls[i].computed
    result[i] = lh.Ls[i].L

proc computeCdf(lh: LimitHelper): seq[float] =
  # get xs and ys
  let xs = lh.couplings()
  let ys = lh.likelihoods()
  result = cdfUnequal(ys, xs)

proc gradientSecond(xs, cdf: seq[float]): seq[float] =
  result = newSeq[float](xs.len)
  let xMax = xs[^1]
  let xMin = xs[0]
  for i in 1 ..< xs.high:
    let s1 = (cdf[i-1] - cdf[i]) / (xs[i-1] - xs[i]) * (xMax - xMin)
    let s2 = (cdf[i+1] - cdf[i]) / (xs[i+1] - xs[i]) * (xMax - xMin)
    ## NOTE: we do *not* want to normalize to the distance between points! That defeats the
    ## purpose. We care about making the slopes similar in absolute terms. Normalizing we
    ## get the real second derivative, but we want the slopes to become "similar enough" instead,
    ## i.e. to define a smoothness
    result[i] = (abs(s2) - abs(s1)) # / ((xs[i+1] - xs[i-1]) / 2.0)

proc computeDeriv(lh: LimitHelper): seq[float] =
  let xs = lh.couplings()
  let cdf = lh.cdf
  doAssert cdf.len == xs.len, "CDF must be up to date!"
  result = gradientSecond(xs, cdf)

proc insert(lh: var LimitHelper, c: float) =
  ## Inserts the given coupling into the heapqueue and computes the likelihood value
  ## associated to the coupling constant for the given `Context`
  let L = lh.ctx.evalAt(lh.cands, c)
  #echo "L: ", L, " at ", c
  let cL = Likelihood(coupling: c,
                      computed: true,
                      L: L)
  lh.Ls.push cL

proc initLimitHelper(ctx: Context, cands: seq[Candidate],
                     couplings: seq[float]): LimitHelper =

  var h = initSortedSeq[Likelihood]()
  result = LimitHelper(ctx: ctx, cands: cands, Ls: h,
                       dy: 0.005,
                       dDeriv: 0.05)
  # insert into the heapqueue
  for c in couplings:
    result.insert(c)
  result.cdf = result.computeCdf()
  result.deriv = result.computeDeriv()

proc derivativesLarger(lh: LimitHelper, than: float): bool =
  ## Checks if any derivatives are larger `than`.
  result = lh.deriv.anyIt(abs(it) > than)

proc computeCouplings(lh: var LimitHelper) =
  let xs = lh.couplings()
  let cdf = lh.cdf
  var x = xs[0]
  var y = cdf[0]
  let der = lh.deriv
  var i = 0
  var j = 0
  #var done: set[uint16]
  while i < xs.high:
    let derv = if der[min(der.high, j)] > 0: der[min(der.high, j)] else: 1.0
    #if i > 0 and abs(cdf[j] - y) > lh.dy:
    #  echo "CASE 1 \n"
    #  lh.insert((xs[i] + x) / 2.0)
    #  inc i
    #TODO: add back above to avoid points after 10
    if i > 0 and abs(derv) > lh.dDeriv and abs(cdf[j] - y) > lh.dy:
      #echo "DIFFERENCE : ", abs(cdf[j] - y), " for ", x, " at j ", j, " of ", cdf.len, " and i ", i, " of ", xs.len
      let xi = xs[i]
      let xi1 = xs[i+1]
      lh.insert((xi + x) / 2.0)
      lh.insert((xi1 + xi) / 2.0)
      #done.incl j.uint16
    #elif j > 0 and der[j] < der[j-1]:
    #  # found a dip, insert
    #  let xi = xs[i]
    #  let xi1 = xs[i+1]
    #  lh.insert((xi + x) / 2.0)
    #  lh.insert((xi1 + xi) / 2.0)
    if i > 0:
      inc i
      inc j
    x = xs[i]
    y = cdf[j]
    inc i
    inc j

proc genplot(lh: LimitHelper, title = "", outname = "/tmp/ragged_cdf.pdf") =
  let xs = lh.couplings()
  let Ls = lh.likelihoods()
  let cdf = lh.cdf
  let lSum = Ls.max
  let df = toDf({ "x" : xs,
                  "L [norm]" : Ls.mapIt(it / lSum),
                  "cdf" : cdf })
    .gather(["cdf", "L [norm]"], key = "Type", value = "val")
  let xm = xs.max
  #df.showbrowser()
  ggplot(df, aes("x", "val", color = "Type")) +
    geom_line() +
    geom_point(size = 1.0) +
    #ylim(0.9, 1.0) +
    geom_linerange(aes = aes(y = 0.95, xMin = 0.0, xMax = xm), lineType = ltDashed, color = "purple") +
    ggtitle(title) +
    ggsave(outname)

proc plotSecond(lh: LimitHelper) {.used.} =
  let der = lh.deriv
  let xx = lh.couplings()
  let df = toDf(xx, der)
  ggplot(df, aes("xx", "der")) +
    geom_line() +
    ggsave("/tmp/cdf_second_der.pdf")

import flatty
when false:
  proc bayesLimit(ctx: Context, cands: seq[Candidate], toPlot: static bool = false): float = # {.gcsafe.} =
    var ctx = ctx
    const nPoints = 10000
    var Ls = newSeqOfCap[float](nPoints)
    var cdfs = newSeqOfCap[float](nPoints)
    var couplings = newSeqOfCap[float](nPoints)
    var coupling = 0.0
    let couplingStep = 1e-22
    var idx = 0

    # 2. compute starting values and add them
    when true:
      let L0 = ctx.evalAt(cands, 0.0)
      cdfs.add L0
      Ls.add L0
      couplings.add coupling
      var curL = L0
      echo "Cur L ", curL
      #echo "L0 = ", L0, " and  curL = ", curL, " abs = ", abs(ln(L0) / ln(curL)), " is nan ?? ", abs(ln(L0) / ln(curL)).isNaN
      #if true: quit()
      # 3. walk from g_ae² = 0 until the ratio of the `ln` values is 0.9. Gives us good margin for CDF
      #    calculation (i.e. make sure the CDF will have plateaued
      var lastL = curL
      var cdfVal = lastL

      var decreasing = false

      var maxVal = curL
      var stopVal = if curL < 5e-3: curL / 200.0 else: 5e-3 #1e-3 #maxVal / 500.0 # if curL < 5e-3: curL / 200.0 else: 5e-3

      while curL > stopVal: # and idx < 1000: #ln(curL) >= 0.0:
        echo "Limit step ", idx, " at curL ", curL, " at g_ae²: ", ctx.g_ae², " decreasing ? ", decreasing, " curL < lastL? ", curL < lastL

        coupling += couplingStep
        curL = ctx.evalAt(cands, coupling)
        maxVal = max(curL, maxVal)
        #stopVal = maxVal / 500.0
        cdfVal += curL
        cdfs.add cdfVal
        Ls.add curL
        couplings.add coupling

        if decreasing and # already decreasing
           curL > lastL:  # rising again! Need to stop!
          echo "Breaking early!"
          #break
        if lastL != curL and curL < lastL:
          # decreasing now!
          decreasing = true

        lastL = curL
        inc idx
    let cdfsNorm = toCDF(cdfs, isCumSum = true)
    # 5. now find cdf @ 0.95
    let idxLimit = cdfsNorm.lowerBound(0.95)
    # 6. coupling at this value is limit
    result = couplings[idxLimit]

when true:
  proc bayesLimit(ctx: Context, cands: seq[Candidate], toPlot: static bool = false): float = # {.gcsafe.} =
    ## compute the limit based on integrating the posterior probability according to
    ## Bayes theorem using a prior that is zero in the unphysical range and constant in
    ## the physical
    # 1. init needed variables
    var ctx = ctx
    var couplings = linspace(0.0, 2e-20, 10)

    var lh = initLimitHelper(ctx, cands, couplings)
    let ε = 0.005 #1e-3
    # with in place, compute derivatives & insert until diff small enough
    var diff = Inf
    var at = 0
    #echo lh.deriv
    #genplot(lh, title = "MC Index: " & $ctx.mcIdx)
    #plotSecond(lh)
    #echo lh.derivativesLarger(0.5)
    var count = 0
    while diff > ε and lh.derivativesLarger(0.5):
      computeCouplings(lh)
      lh.cdf = lh.computeCdf()
      lh.deriv = lh.computeDeriv()
      at = lh.cdf.lowerBound(0.95)
      diff = lh.cdf[at] - 0.95
      #echo "XS : ", xs
      #echo "Diff ", diff, " at ", lh.cdf[at], " x ", lh.Ls[at]
      genplot(lh, title = "MC Index: " & $ctx.mcIdx)
      #plotSecond(lh)
      #sleep(300)
      inc count
      if count > 1000:
        writeFile(&"/tmp/reference_candidates_{count}_s_{ctx.σsb_sig}_b_{ctx.σsb_back}.bin", cands.toFlatty())
        echo "At count ", count, " for ctx "#, ctx
        quit()
    #echo "Final x: ", xs, " of length: ", xs.len, " and dervs ", dervs
    echo "Diff: ", diff
    if false: #ctx.mcIdx == 44:
      writeFile("/tmp/reference_candidates.bin", cands.toFlatty())
      quit()
    couplings = lh.couplings()

    result = couplings[at] #couplings[idxLimit]
    when false: #true:# false: # toPlot:
      let Ls = lh.likelihoods()
      let cdfsNorm = lh.cdf #toCDF(cdfs, isCumSum = true)
      let df = toDf({"Ls" : Ls, "cdfsNorm" : cdfsNorm, "couplings" : couplings})
      #df.showBrowser()
      ggplot(df.mutate(f{"logL" ~ ln(`Ls`)}), aes("couplings", "logL")) +
        geom_line() + ggsave("/tmp/couplings_vs_ln_likelihood.pdf")
      ggplot(df, aes("couplings", "cdfsNorm")) +
        geom_line() + ggsave("/tmp/couplings_vs_cdfsNorm_ln_likelihood.pdf")
      ggplot(df, aes("couplings", "Ls")) +
        geom_line() + ggsave("/tmp/couplings_vs_likelihood.pdf")

proc extractFromChain(chain: seq[seq[float]], names: seq[string]): DataFrame =
  ## Turns a given markov chain into a DF for easier future processing (and plotting)
  ##
  ## Nuisance parameter columns will be filled in case they exist in the chain.
  let nPar = chain[0].len
  doAssert names.len == nPar - 1, "names.len " & $names.len & " vs (nPar - 1) " & $(nPar - 1) # - 1 as `g_ae²` is additional parameter
  # allocate tensors of the right size to avoid copying on DF construction
  var
    gs = zeros[float](chain.len)
    θs = newSeq[Tensor[float]](nPar - 1)
  for θ in mitems(θs):
    θ = zeros[float](chain.len)
  for i in 0 ..< chain.len:
    let c = chain[i]
    gs[i] = c[0]
    for j in 0 ..< names.len:
      θs[j][i] = c[1 + j] # + 1 as 0-th param is `g_ae²`
  result = toDf({"gs" : gs})
  for i, name in names:
    result[name] = θs[i]

proc computeLimitFromMCMC(df: DataFrame): float =
  ## Given the DF conbtaining the markov chain, computes the limit according to a
  ## 95 percentile of the CDF (or technically empirical distribution fn. {EDF}).
  let (xCdf, cdf) = unbinnedCdf(df["gs", float])
  let c95Idx = cdf.lowerBound(0.95)
  result = xCdf[c95Idx]
  echo "Limit at ", result

proc plotChain(ctx: Context, cands: seq[Candidate], chainDf: DataFrame,
               limit: float, computeIntegral = false) =
  ## generates plots for the given context, candidates, limit and DF resulting from
  ## a markov chain. If `computeIntegral` is true it also computes a the likelihood
  ## values using numerical integration as a cross check.
  let nPar = chainDf.getKeys.len

  echo "Number of candidates: ", cands.len
  if limit > 9e-21 and cands.len > 0:
    plotCandidates(cands)

  # plotting
  ## XXX: replace operations using `gs` by something that can work on tensor!
  let gs = chainDf["gs", float].toSeq1D
  var dfA: DataFrame
  if computeIntegral:
    let nBins = 50
    let (hist, _) = histogram(gs, bins = nBins)
    let hMax = hist.max
    var Ls = newSeq[float]()
    let coups = linspace(0.0, 1.4e-20, 20)
    if not fileExists("/tmp/likelihood.bin"):
      echo "Computing the integration"
      let t0 = epochTime()
      for i, gae in coups:
        echo "At idx ", i
        Ls.add ctx.evalAt(cands, gae)
      echo "Integration took ", epochTime() - t0
      writeFile("/tmp/likelihood.bin", Ls.toFlatty())
    else:
      Ls = fromFlatty(readFile("/tmp/likelihood.bin"), seq[float])
      echo "Limit from Ls ", coups[cdfUnequal(Ls.mapIt(it.float), coups).lowerBound(0.95)]
    let Lmax = Ls.max
    echo "LS max ", Lmax
    dfA = toDf(coups, Ls)
      .mutate(f{"Ls" ~ `Ls` / Lmax * hMax})

  #when false:
  if limit > 1e-19:
    echo zip(toSeq(0 ..< gs.len), gs).filterIt(it[1] > 1e-19)
    echo "Number of states with L > 5e-20: ", zip(toSeq(0 ..< gs.len), gs).filterIt(it[1] > 5e-20).len

    echo "Number of elements below 2e-20: ", gs.filterIt(it <= 2e-20).len
    echo "Number of elements above 2e-20: ", gs.filterIt(it > 2e-20).len
    let tr = color(0.0, 0.0, 0.0, 0.0)
    let bt = color(0.0, 0.0, 0.0, 0.5)
    if nPar > 4:
      #if cands.len > 0:
      ggplot(chainDf, aes("gs", "θs_y", color = "θs_x")) +
        geom_line(size = 0.5) + geom_point(size = 1.0, alpha = 0.1) +
        #geom_histogram(bins = 50, density = true) +
        ggsave("/tmp/mcmc_lines.png", width = 1200, height = 800)
      ggplot(chainDf, aes("θs_x", "θs_y", color = "gs")) +
        geom_line(size = 0.5) + geom_point(size = 1.0, alpha = 0.1) +
        #geom_histogram(bins = 50, density = true) +
        ggsave("/tmp/mcmc_lines_thetas_xy.png", width = 1200, height = 800)
    if nPar > 1:
      ggplot(chainDf, aes("θs_s", "θs_b", color = "gs")) +
        #geom_line(size = 0.5, color = bt, fillColor = tr) + geom_point(size = 1.0, alpha = 0.1) +
        geom_line(size = 0.5) + geom_point(size = 1.0, alpha = 0.1) +
        #geom_histogram(bins = 50, density = true) +
        ggsave("/tmp/mcmc_lines_thetas_sb.png", width = 1200, height = 800)
    #quit()

  #echo chainDf
  when true:
    let nBins = 50
    let (hist, bins) = histogram(gs, bins = nBins)
    let c95IdxHisto = bins.lowerBound(limit)
    let dfSub = toDf({"Bins" : bins[c95IdxHisto ..< ^1], "Hist" : hist[c95IdxHisto .. ^1] })
    var plt = ggplot(chainDf, aes("gs")) +
      geom_histogram(
        bins = nBins, density = false, hdKind = hdOutline, alpha = 0.5,
        lineWidth = 1.5, fillColor = "blue") +
      geom_histogram(
        data = dfSub, aes = aes("Bins", "Hist"), stat = "identity",
        hdKind = hdOutline, lineWidth = 1.5, fillColor = "red") +
      annotate(x = bins[c95IdxHisto], y = hist[c95IdxHisto].float + 500.0,
               text = "Limit at 95% area") +
      xlab("g_ae²") + ylab("L (MCMC sampled)") +
      ggtitle("Determination of the limit for a single set of candidates")
    if computeIntegral:
      plt = plt + geom_line(data = dfA, aes = aes("coups", "Ls"), color = "orange")
    plt + ggsave("/tmp/mcmc_histo.pdf", width = 800, height = 480)
  when false:
    ## XXX: these would require information from the `computeLimitFromMCMC` procedure, i.e. the CDF / EDF
    ggplot(toDf({"Bins" : bins[0 .. ^2], "cdf" : cdfTC}), aes("Bins", "cdf")) +
      geom_line() +
      ggsave("/tmp/mcmc_cdf_from_tocdf.pdf")

    ggplot(toDf({"gae²" : xCdf, "cdf" : cdf}), aes("gae²", "cdf")) +
      geom_line() +
      ggsave("/tmp/mcmc_cdf.pdf")

    #ggplot(toDf({"Bins" : bins[0 .. ^2], "cumSum" : hist.mapIt(it.float).cumSum()}), aes("Bins", "cumSum")) +
    #  geom_line() +
    #  ggsave("/tmp/mcmc_cumSum.pdf")


    if min(bins) < 0.0: quit()

type
  LogProc = proc(x: seq[float]): float

template rand(rnd: var Random, slice: Slice[float]): untyped =
  var u = uniform(slice.a, slice.b)
  rnd.sample(u)

template rand(rnd: var Random, to: float): untyped =
  var u = uniform(0.0, to)
  rnd.sample(u)

proc proposal(rnd: var Random, x: seq[float], stepsize: seq[float]): seq[float] =
  result = newSeq[float](x.len)
  for i in 0 ..< x.len:
    # for now all uniform in a
    result[i] = rnd.rand(x[i] - 0.5 * stepsize[i] .. x[i] + 0.5 * stepsize[i])

#proc p_acc_MH(xNew, xOld: seq[float], logProc: LogProc): float =
#  result = min(1.0, logProc(xNew) / logProc(xOld))

proc p_acc_MH(logNew, logOld: float): float =
  result = min(1.0, logNew / logOld)

proc sample_MH(
  rnd: var Random,
  xOld, stepsize: seq[float],
  logOld: float,
  logProc: LogProc): tuple[accept: bool, xNew: seq[float], logVal: float] =

  let xNew = rnd.proposal(xOld, stepsize)
  let logNew = logProc(xNew)
  let accept = rnd.rand(1.0) < p_acc_MH(logNew, logOld)
  #if accept and logNew == 0.0: # and logOld == 0.0: #  (xNew[0] < 0.0 or xNew[4] > 2.0):
  #  echo "lognew ? ", logNew, " accept ", accept, " for ", p_acc_MH(logNew, logOld), " lognew ", logNew, " logold ", logold
  if accept:
    result = (accept: true, xNew: xNew, logVal: logNew)
  else:
    result = (accept: false, xNew: xOld, logVal: logOld)

proc build_MH_chain(rnd: var Random, init, stepsize: seq[float], nTotal: int,
                    logProc: LogProc): (seq[seq[float]], float) =
  var nAccepted = 0
  var chain = newSeq[seq[float]](nTotal+1)
  chain[0] = init
  let t0 = epochTime()
  # compute starting value of function
  var logVal = logProc(init)
  var accept: bool
  var state: seq[float]
  for i in 0 ..< nTotal:
    (accept, state, logVal) = rnd.sample_MH(chain[i], stepsize, logVal, logProc)
    if state[0] < 0.0:# or state[4] > 2.0:
      echo state, " at index ", i
      quit()
    chain[i+1] = state
    if accept:
      inc nAccepted
  echo "Building chain of ", nTotal, " elements took ", epochTime() - t0, " s"
  result = (chain, nAccepted.float / nTotal.float)

## The following 3 templates defining functions are dirty so that `cSigBack` is visible after
## the template was called.
template fullUncertainFn(): untyped {.dirty.} =
  doAssert ctx.uncertaintyPosition == puUncertain
  doAssert ctx.uncertainty == ukUncertain, "Position uncertainty only implemented with s/b uncertainty so far"
  ctx.g_ae² = 1e-13 * 1e-13 ## to have reference values to quickly rescale!
  var cSigBack = newSeq[(float, float)](cands.len)
  let
    SQRT2 = sqrt(2.0)
    σ_s = ctx.σsb_sig
    σ_b = ctx.σsb_back
    s_tot = expRate(ctx)

  let σ_p = ctx.σ_p
  for i, c in cands:
    let sig = ctx.detectionEff(c.energy) * ctx.axionFlux(c.energy) * conversionProbability()
    cSigBack[i] = (sig.float,
                ctx.background(c.energy, c.pos).float)

  proc fn(x: seq[float]): float =
    ctx.g_ae² = x[0]
    let (θ_s, θ_b, θ_x, θ_y) = (x[1], x[2], x[3], x[4])
    if x[0] < 0.0: return -1.0
    elif θ_b < -0.8 or θ_b > 1.0: return -1.0
    elif θ_s < -1.0 or θ_s > 1.0: return -1.0
    elif θ_x > 1.0  or θ_x < -1.0: return -1.0
    elif θ_y > 1.0  or θ_y < -1.0: return -1.0
    let s_totg = s_tot.rescale(ctx.g_ae²)
    #echo "rescaled ", s_tot, " to ", s_totg
    ctx.θ_x = θ_x
    ctx.θ_y = θ_y
    ## TODO: convert to logsumexp or similar?
    let P1 = exp(-s_totg)
    let P2 = exp(-pow(θ_x / (SQRT2 * σ_p), 2)) * exp(-pow(θ_y / (SQRT2 * σ_p), 2)) *
             exp(-pow(θ_s / (SQRT2 * σ_s), 2)) * exp(-pow(θ_b / (SQRT2 * σ_b), 2))
    var P3 = 1.0
    for i in 0 ..< cSigBack.len:
      let (s_init, b_c) = cSigBack[i]
      if b_c.float != 0.0:
        let s_c = (s_init.rescale(ctx.g_ae²) * (1 + θ_s) * ctx.raytracing(cands[i].pos)).float
        P3 *= (1 + s_c / (b_c * (1 + θ_b)))
    result = abs(P1 * P2 * P3) # make positive if number comes out to `-0.0`

template posUncertainFn(): untyped {.dirty.} =
  doAssert ctx.uncertaintyPosition == puUncertain
  doAssert ctx.uncertainty == ukCertain, "Position certainty required here"
  ctx.g_ae² = 1e-13 * 1e-13 ## to have reference values to quickly rescale!
  var cSigBack = newSeq[(float, float)](cands.len)
  let
    SQRT2 = sqrt(2.0)
    s_tot = expRate(ctx)

  let σ_p = ctx.σ_p
  for i, c in cands:
    let sig = ctx.detectionEff(c.energy) * ctx.axionFlux(c.energy) * conversionProbability()
    cSigBack[i] = (sig.float,
                   ctx.background(c.energy, c.pos).float)

  proc fn(x: seq[float]): float =
    ctx.g_ae² = x[0]
    let (θ_x, θ_y) = (x[1], x[2])
    if x[0] < 0.0: return -1.0
    elif θ_x > 1.0  or θ_x < -1.0: return -1.0
    elif θ_y > 1.0  or θ_y < -1.0: return -1.0
    let s_totg = s_tot.rescale(ctx.g_ae²)
    #echo "rescaled ", s_tot, " to ", s_totg
    ctx.θ_x = θ_x
    ctx.θ_y = θ_y
    ## TODO: convert to logsumexp or similar?
    let P1 = exp(-s_totg)
    let P2 = exp(-pow(θ_x / (SQRT2 * σ_p), 2)) * exp(-pow(θ_y / (SQRT2 * σ_p), 2))
    var P3 = 1.0
    for i in 0 ..< cSigBack.len:
      let (s_init, b_c) = cSigBack[i]
      if b_c.float != 0.0:
        let s_c = (s_init.rescale(ctx.g_ae²) * ctx.raytracing(cands[i].pos)).float
        P3 *= (1 + s_c / b_c)
    result = abs(P1 * P2 * P3) # make positive if number comes out to `-0.0`

template sbUncertainFn(): untyped {.dirty.} =
  doAssert ctx.uncertaintyPosition == puCertain
  doAssert ctx.uncertainty == ukUncertain
  ctx.g_ae² = 1e-13 * 1e-13 ## to have reference values to quickly rescale!
  var cSigBack = newSeq[(float, float)](cands.len)
  let
    σ_s = ctx.σsb_sig
    σ_b = ctx.σsb_back
    s_tot = expRate(ctx)
  for i, c in cands:
    cSigBack[i] = (ctx.expectedSignal(c.energy, c.pos).float,
                   ctx.background(c.energy, c.pos).float)
  proc fn(x: seq[float]): float =
    ctx.g_ae² = x[0]
    #echo "Parameters: ", x
    let g_ae = x[0]
    let θ_s = x[1]
    let θ_b = x[2]
    if g_ae < 0.0:
      #echo "Invalid, return 0"
      return -1.0
    if θ_b < -0.8 or θ_b > 1.0: return -1.0
    if θ_s < -1.0 or θ_s > 2.0: return -1.0
    let s_totg = s_tot.rescale(ctx.g_ae²)
    L(s_totg,
      s_i.rescale(ctx.g_ae²) * (1 + θ_s),
      b_i * (1 + θ_b),
      θ_s, σ_s,
      θ_b, σ_b)
    result = abs(result) # make positive if number comes out to `-0.0`

template certainFn(): untyped {.dirty.} =
  doAssert ctx.uncertaintyPosition == puCertain
  doAssert ctx.uncertainty == ukCertain
  ctx.g_ae² = 1e-13 * 1e-13 ## to have reference values to quickly rescale!
  var cSigBack = newSeq[(float, float)](cands.len)
  let s_tot = expRate(ctx)
  for i, c in cands:
    cSigBack[i] = (ctx.expectedSignal(c.energy, c.pos).float,
                   ctx.background(c.energy, c.pos).float)

  proc fn(x: seq[float]): float =
    ctx.g_ae² = x[0]
    #echo "Parameters: ", x
    if x[0] < 0.0:
      #echo "Invalid, return 0"
      return -1.0
    let s_totg = s_tot.rescale(ctx.g_ae²)
    L(s_totg,
      s_i.rescale(ctx.g_ae²),
      b_i,
      0.0, 0.0,
      0.0, 0.0)
    result = abs(result) # make positive if number comes out to `-0.0`

proc build_MH_chain(ctx: Context, rnd: var Random, cands: seq[Candidate],
                    log: Logger = nil): seq[seq[float]] =
  ## Builds the appropriate chain given the systematics (or lack thereof) of the given
  ## `ctx` and the given candidates `cands`.
  ##
  ## Returns the built markov chain as a sequence of parameters (i.e. seq[seq[float]]).
  let t0 = getMonoTime()
  case ctx.uncertaintyPosition
  of puUncertain:
    case ctx.uncertainty
    of ukUncertain:
      fullUncertainFn() ## defines `fn` and `cSigBack`
      #let (chain, acceptanceRate) = build_MH_chain(@[0.1e-21, 0.1, 0.2, 0.5, -0.5], @[3e-21, 0.025, 0.025, 0.05, 0.05], 100_000, fn)
      const nChains = 3
      ## Burn in of 50,000 was deemed fine even for extreme walks in L = 0 space
      const BurnIn = 50_000
      var totalChain = newSeq[seq[float]]()
      for i in 0 ..< nChains:
        let start = @[rnd.rand(0.0 .. 5.0) * 1e-21, # g_ae²
                      rnd.rand(-0.4 .. 0.4), rnd.rand(-0.4 .. 0.4), # θs, θb
                      rnd.rand(-0.5 .. 0.5), rnd.rand(-0.5 .. 0.5)] # θx, θy
        echo "\t\tInitial chain state: ", start
        let (chain, acceptanceRate) = rnd.build_MH_chain(start, @[3e-21, 0.025, 0.025, 0.05, 0.05], 150_000, fn)
        echo "Acceptance rate: ", acceptanceRate, " with last two states of chain: ", chain[^2 .. ^1]
        totalChain.add chain[BurnIn .. ^1]
      ## TODO: not only return the limit, but also the acceptance rate!
      result = totalChain
    of ukCertain:
      posUncertainFn() ## defines `fn` and `cSigBack`
      const nChains = 3
      ## Burn in of 50,000 was deemed fine even for extreme walks in L = 0 space
      const BurnIn = 50_000
      var totalChain = newSeq[seq[float]]()
      for i in 0 ..< nChains:
        let start = @[rnd.rand(0.0 .. 5.0) * 1e-21, # g_ae²
                      rnd.rand(-0.5 .. 0.5), rnd.rand(-0.5 .. 0.5)] # θx, θy
        echo "\t\tInitial chain state: ", start
        let (chain, acceptanceRate) = rnd.build_MH_chain(start, @[3e-21, 0.05, 0.05], 150_000, fn)
        echo "Acceptance rate: ", acceptanceRate, " with last two states of chain: ", chain[^2 .. ^1]
        totalChain.add chain[BurnIn .. ^1]
      ## TODO: not only return the limit, but also the acceptance rate!
      result = totalChain
    else: doAssert false, "Currently unsupported (posUncertain + s/b certain combination)"
  of puCertain:
    case ctx.uncertainty
    of ukUncertain:
      sbUncertainFn()
      const nChains = 3
      ## Burn in of 50,000 was deemed fine even for extreme walks in L = 0 space
      const BurnIn = 50_000
      var totalChain = newSeq[seq[float]]()
      for i in 0 ..< nChains:
        let start = @[rnd.rand(0.0 .. 5.0) * 1e-21, # g_ae²
                      rnd.rand(-0.4 .. 0.4), rnd.rand(-0.4 .. 0.4)] # θs, θb
        echo "\t\tInitial chain state: ", start

        ## XXX: really seems to converge to a different minimum than the one found by the scan
        let (chain, acceptanceRate) = rnd.build_MH_chain(start, @[5e-21, 0.01, 0.01], 200_000, fn)
        echo "Acceptance rate: ", acceptanceRate, " with last two states of chain: ", chain[^2 .. ^1]
        totalChain.add chain[BurnIn .. ^1]
      ## TODO: not only return the limit, but also the acceptance rate!
      result = totalChain

      when false:
        let (chain, acceptanceRate) = rnd.build_MH_chain(@[0.5e-21, 0.05, -0.05], @[3e-21, 0.025, 0.025], 500_000, fn)
        echo "Acceptance rate: ", acceptanceRate
        echo "Last ten states of chain: ", chain[^10 .. ^1]
        ## TODO: not only return the limit, but also the acceptance rate!
        result = chain
    of ukCertain:
      certainFn()
      let (chain, acceptanceRate) = rnd.build_MH_chain(@[0.5e-21], @[1e-21], 100_000, fn)
      echo "Acceptance rate: ", acceptanceRate
      echo "Last ten states of chain: ", chain[^10 .. ^1]
      ## TODO: not only return the limit, but also the acceptance rate!
      result = chain
    else: doAssert false, "Not supported for MCMC yet"
  let t1 = getMonoTime()
  if not log.isNil:
    log.info "Building MCMC with systematics " & ctx.systematics.pretty() &
      " of final length " & $result.len & " took " & $(t1 - t0) & " s"

proc computeMCMCLimit(ctx: Context, rnd: var Random, cands: seq[Candidate]): float =
  ## Builds the required MCMC and computes the limit based on it.
  let chain = ctx.build_MH_chain(rnd, cands)
  let names = if ctx.systematics.uncertainty == ukUncertain and ctx.systematics.uncertaintyPosition == puUncertain:
                @["θs_s", "θs_b", "θs_x", "θs_y"]
              elif ctx.systematics.uncertainty == ukUncertain and ctx.systematics.uncertaintyPosition == puCertain:
                @["θs_s", "θs_b"]
              elif ctx.systematics.uncertainty == ukCertain and ctx.systematics.uncertaintyPosition == puUncertain:
                @["θs_x", "θs_y"]
              else:
                @[]
  let df = extractFromChain(chain, names)
  result = computeLimitFromMCMC(df)
  ctx.plotChain(cands, df, result, computeIntegral = false)

proc candsInSens(ctx: Context, cands: seq[Candidate], cutoff = 0.5): int =
  var ctx = ctx
  # use a fixed g_ae² for the computation here
  ctx.g_ae² = pow(8.1e-11, 2.0)
  for c in cands:
    let sig = ctx.expectedSignal(c.energy, c.pos)
    if ln(1 + sig / ctx.background(c.energy, c.pos)) >= cutoff:
      inc result

type
  LimitKind = enum
    lkSimple,     ## purely physical region going down to 95% equivalent
    lkScan,       ## proper scan for maximum using a binary approach
    lkLinearScan, ## limit based on linear scan in pre defined range
    lkBayesScan,   ## limit based on integrating bayes theorem (posterior prob.)
    lkMCMC

proc computeLimit(ctx: Context, rnd: var Random,
                  cands: seq[Candidate],
                  limitKind: LimitKind,
                  toPlot: static bool = false): float =
  #{.cast(gcsafe).}:
  case limitKind
  of lkBayesScan:
    result = ctx.bayesLimit(cands, toPlot = toPlot)
  of lkMCMC:
    result = ctx.computeMCMCLimit(rnd, cands)
  else:
    doAssert false, "Unsupported limit calculation type"

proc expectedLimit(limits: seq[float]): float =
  ## Returns the expected limit of a set of MC toy experiment limits.
  ## Currently it's just defined as the median of the determined limits.
  result = limits.median(q = 50)

proc plotMCLimitHistogram(
  ctx: Context, limits: seq[float], candsInSens: seq[int],
  limitKind: LimitKind, nmc: int,
  limitNoSignal: float, expLimit = Inf,
  bins = 50,
  xlimit = (0.0, 0.0),
  ylimit = (0.0, 0.0),
  xLabel = "Limit", yLabel = "Count",
  linesTo = 1000,
  outpath = "/tmp/",
  suffix = "") =
  let expLimit = if classify(expLimit) == fcInf: expectedLimit limits
                 else: expLimit
  echo "Expected limit: ", expLimit
  var dfL = toDf(limits, candsInSens)
  var ufSuff: string
  var utSuff: string
  case ctx.uncertainty
  of ukCertain:
    ufSuff = &"uncertainty_{ctx.uncertainty}"
    utSuff = &"{ctx.uncertainty}"
  of ukUncertainSig:
    ufSuff = &"uncertainty_{ctx.uncertainty}_σs_{ctx.σs_sig:.4f}"
    utSuff = &"{ctx.uncertainty}, σs = {ctx.σs_sig:.4f}"
  of ukUncertainBack:
    ufSuff = &"uncertainty_{ctx.uncertainty}_σb_{ctx.σb_back:.4f}"
    utSuff = &"{ctx.uncertainty}, σb = {ctx.σb_back:.4f}"
  of ukUncertain:
    ufSuff = &"uncertainty_{ctx.uncertainty}_σs_{ctx.σsb_sig:.4f}_σb_{ctx.σsb_back:.4f}"
    utSuff = &"{ctx.uncertainty}, σs = {ctx.σsb_sig:.4f}, σb = {ctx.σsb_back:.4f}"
  var pufSuff: string
  var putSuff: string
  case ctx.uncertaintyPosition
  of puCertain:
    pufSuff = &"posUncertain_{ctx.uncertaintyPosition}"
    putSuff = &"{ctx.uncertaintyPosition}"
  of puUncertain:
    pufSuff = &"posUncertain_{ctx.uncertaintyPosition}_σp_{ctx.σ_p:.4f}"
    putSuff = &"{ctx.uncertaintyPosition}, σp = {ctx.σ_p:.4f}"
  dfL.writeCsv(&"{outpath}/mc_limit_{limitKind}_{ctx.samplingKind}_nmc_{nmc}_{ufSuff}_{pufSuff}{suffix}.csv")

  let maxVal = if xlimit[1] > 0.0: xLimit[1] else: 3e-20
  dfL = dfL
    #.filter(f{`limits` < 2e-19})
    .filter(f{`limits` < maxVal})
  var plt = ggplot(dfL, aes("limits", fill = factor("candsInSens"))) +
    geom_histogram(bins = bins, hdKind = hdOutline, position = "identity", alpha = some(0.5)) +
    geom_linerange(aes = aes(x = limitNoSignal, y = 0.0, yMin = 0.0, yMax = linesTo),
                   color = some(parseHex("FF0000"))) +
    geom_linerange(aes = aes(x = expLimit, y = 0.0, yMin = 0.0, yMax = linesTo),
                   color = some(parseHex("0000FF"))) +
    annotate(text = "Limit w/o signal, only R_T",
             x = limitNoSignal - 0.2e-21,
             y = linesTo.float,
             rotate = -90.0,
             font = font(color = parseHex("FF0000")),
             alignKind = taRight,
             backgroundColor = color(0.0, 0.0, 0.0, 0.0)) +
    annotate(text = "Expected limit",
             x = expLimit + 0.01e-21,
             y = linesTo.float,
             rotate = -90.0,
             font = font(color = parseHex("0000FF")),
             backgroundColor = color(0.0, 0.0, 0.0, 0.0)) +
    scale_x_continuous() + scale_y_continuous() +
    margin(top = 1.5)
  if xlimit[0] != xlimit[1]:
    plt = plt + xlim(xlimit[0], xlimit[1])
  if ylimit[0] != ylimit[1]:
    plt = plt + ylim(ylimit[0], ylimit[1])
  plt +
    xlab(xLabel) + ylab(yLabel) +
    ggtitle(&"MC limit histogram of {nmc} toys using {ctx.samplingKind} and {limitKind}. {utSuff} " &
            &"{putSuff}. Expected limit g_ae² = {expLimit:.4e}") +
    ggsave(&"{outpath}/mc_limit_{limitKind}_{ctx.samplingKind}_nmc_{nmc}_{ufSuff}_{pufSuff}{suffix}.pdf",
            width = 800, height = 480)

proc monteCarloLimits(ctx: Context, rnd: var Random, limitKind: LimitKind,
                      nmc = 1000): float =
  # 1. determine limit of no signal
  let candsNoSignal = newSeq[Candidate]() #ctx.drawCandidates(rnd, posOverride = some((x: 14.0, y: 14.0)))
  let limitNoSignal = ctx.computeLimit(rnd, candsNoSignal, limitKind)
  # 2. perform regular limit calc using simple limit
  var limits = newSeq[float](nmc)
  var candsInSens = newSeq[int](nmc)
  for i in 0 ..< nmc:
    #if i mod 10 == 0:
    echo "MC index ", i, "\n\n"
    ctx.mcIdx = i
    #{.cast(gcsafe).}:
    let cands = ctx.drawCandidates(rnd)
    limits[i] = ctx.computeLimit(rnd, cands, limitKind)
    candsInSens[i] = candsInSens(ctx, cands)
    echo "Running expected limit: ", expectedLimit(limits[0 ..< i])

  result = limits.expectedLimit()
  when true:
    ctx.plotMCLimitHistogram(limits, candsInSens, limitKind, nmc,
                             limitNoSignal = limitNoSignal, expLimit = result)


when false:
  #import weave
  #import std / threadpool
  #import taskpools
  import threading / channels

  #var chan: Channel[tuple[σ_s, σ_b: float]]
  #var chanRes: Channel[tuple[σ_s, σ_b, limit: float]]
  var chan = newChan[tuple[σ_s, σ_b: float]]()
  var chanRes = newChan[tuple[σ_s, σ_b, limit: float]]()

  template singleTmpl(setup, sendStep: untyped): untyped {.dirty.} =
    let (ctxP, limitKind, id) = tup
    echo ctxP.isNil
    let ctx = ctxP[]
    var rnd = wrap(initMersenneTwister(id.uint32))
    var nMsg = 0
    while nMsg >= 0: # break if channel closed (peek returns -1)
      echo "In thread ", id, " doing things is channel empty? ", chan.peek()
      if nMsg == 0:
        sleep(100)
      else:
        # get a message & process
        setup
        let res = ctx.monteCarloLimits(rnd, limitKind, nmc = 1)
        sendStep
      nMsg = chan.peek()
    echo "Thread ", id, " shutting down!"

  proc singleLimit(tup: tuple[ctx: ptr Context, limitKind: LimitKind, id: int]) {.thread.} =
    singleTmpl:
      var σTup: tuple[σ_s, σ_b: float]
      chan.recv(σTup)
      #let (σ_s, σ_b) = chan.recv()
      ctx.σsb_sig = σTup.σ_s#σ_s
      ctx.σsb_back = σTup.σ_b #σ_b
      echo "Thread ", id, " computing limit ", σTup #σ_s, ", ", σ_b
    do:
      let (σ_s, σ_b) = σTup
      chanRes.send((σs, σb, res))

  proc computeSigmaLimits(ctx: Context, limitKind: LimitKind): seq[tuple[σ_s, σ_b, limit: float]] =
    var σVals = @[0.25, 0.3] #0.05, 0.1, 0.15, 0.2, 0.25, 0.3]
    var σ_pairs = newSeq[(float, float)]()
    for σ_s in σVals:
      #for σ_b in σVals:
      σ_pairs.add (σ_s, σ_s)

    #chan.open()
    #chanRes.open()

    # create threadpool
    const nThreads = 2
    var thr = newSeq[Thread[tuple[ctx: ptr Context, limitKind: LimitKind, id: int]]](nThreads)
    for i in 0 ..< nThreads:
      let ctxL = ctx.clone()
      createThread(thr[i], singleLimit, (ctxL.addr, limitKind, i))

    for p in σ_pairs:
      chan.send(p)

    while result.len != σ_pairs.len:
      var res: tuple[σ_s, σ_b, limit: float]
      #let res = chanRes.recv()
      chanRes.recv(res)
      result.add res
      echo "Received ", res, " in total now ", result.len, " of ", σ_pairs.len

    #chan.close()
    #chanRes.close()
    joinThreads(thr)

  proc compSigmalLimitsSerial(ctx: Context, limitKind: LimitKind): seq[tuple[σ_s, σ_b, limit: float]] =
    var σ_pairs = newSeq[(float, float)]()
    var σVals = @[0.05, 0.1, 0.15, 0.2, 0.25, 0.3]
    for σ_s in σVals:
      σ_pairs.add (σ_s, σ_s)

    var rnd = wrap(initMersenneTwister(1234.uint32))
    for (σ_s, σ_b) in σ_pairs:
      ctx.σsb_sig = σ_s
      ctx.σsb_back = σ_b
      let res = ctx.monteCarloLimits(rnd, limitKind, nmc = 50)
      result.add (σ_s, σ_b, res)

when false:
  #import weave
  #import std / threadpool
  import taskpools

  proc singleLimit(ctxP: ptr Context, σ_s, σ_b: float, limitKind: LimitKind, id: int): float =
    echo ctxP.isNil
    let ctx = ctxP[]
    ctx.σsb_sig = σ_s
    ctx.σsb_back = σ_b
    var rnd = wrap(initMersenneTwister(id.uint32))
    result = ctx.monteCarloLimits(rnd, limitKind, nmc = 50)

  proc computeSigmaLimits(ctx: Context, limitKind: LimitKind): seq[tuple[σ_s, σ_b, limit: float]] =
    var σVals = @[0.05, 0.1, 0.15, 0.2, 0.25, 0.3]
    var σ_pairs = newSeq[(float, float)]()
    for σ_s in σVals:
      #for σ_b in σVals:
      σ_pairs.add (σ_s, σ_s)

    # create threadpool
    const nThreads = 12
    var tp = new(Taskpool, nThreads)
    var res = newSeq[Flowvar[float]](σVals.len)
    #var res = newSeq[float](σVals.len)
    for i in 0 ..< σVals.len:
      let ctxL = ctx.clone()
      echo "Spawning i ", i
      #res[i] = singleLimit(ctxL.addr, σVals[i], σVals[i], limitKind, i)
      res[i] = tp.spawn(singleLimit(ctxL.addr, σVals[i], σVals[i], limitKind, i))

    for i in 0 ..< σVals.len:
      #result.add((σ_s: σpairs[i][0], σ_b: σpairs[i][1], limit: res[i]))
      result.add((σ_s: σpairs[i][0], σ_b: σpairs[i][1], limit: sync(res[i])))

    tp.syncAll()
    tp.shutdown()

when true:
  type
    ProcData = object
      id: int
      σ_s: float
      σ_b: float
      nmc: int

    ProcResult = object
      id: int
      σ_s: float
      σ_b: float
      limit: float

  proc computeSigmaLimits(ctx: Context, limitKind: LimitKind,
                          nmc = 500): seq[tuple[σ_s, σ_b, limit: float]] =
    #var σVals = @[0.25, 0.3] #0.05, 0.1, 0.15, 0.2, 0.25, 0.3]
    var σVals = @[0.05, 0.1, 0.15, 0.2, 0.25, 0.3]
    # adjust `systematics` to allow for `σsb_sig/back`
    ctx.systematics = initSystematics(uncertainty = some(ukUncertain))
    var pp = initProcPool(
      (proc(r, w: cint) =
         var p: ProcData
         let o = open(w, fmWrite)
         let i = open(r)
         while i.uRd(p):
           echo "Starting work for ", p
           var rnd = wrap(initMersenneTwister(p.id.uint32))
           ctx.σsb_sig = p.σ_s
           ctx.σsb_back = p.σ_b
           let res = ctx.monteCarloLimits(rnd, limitKind, nmc = p.nmc)
           echo "\n\n\tMonte Carlo limit from id : ", p.id, " = ", res
           var pRes = ProcResult(id: p.id, σ_s: p.σ_s, σ_b: p.σ_b, limit: res)
           doAssert o.uWr(pRes)
           #flushFile o # needed?
      ),
      # different input and output sizes
      framesOb, jobs = countProcessors(), #auxIn = ProcData.sizeof, auxOut = ProcResult.sizeof,
      aux = ProcResult.sizeof
    )

    var σ_pairs = newSeq[ProcData]()
    for i, σ_s in σVals:
      for j, σ_b in σVals:
        σ_pairs.add ProcData(σ_s: σ_s,
                             σ_b: σ_b,
                             id: i * σVals.len + j,
                             nmc: nmc)

    var limits = newSeq[tuple[σ_s, σ_b, limit: float]](σ_pairs.len)
    var getRes = proc(s: MSlice) =
      var p: ProcResult
      s.toOb(p)
      doAssert p.id < limits.len, "Parsed bad data!"
      limits[p.id] = (σ_s: p.σ_s, σ_b: p.σ_b, limit: p.limit)
    pp.evalOb σ_pairs, getRes
    echo limits # got some data back despite stdout usage!
    result = limits

  template limitsWorker(): untyped {.dirty.} =
    (proc(r, w: cint) =
       let i = open(r)
       var p: ProcData
       while i.uRd(p):
         echo "Starting work for ", p, " at r = ", r, " and w = ", w
         var rnd = wrap(initMersenneTwister(p.id.uint32))
         var results = newSeq[(float, int)]()
         for i in 0 ..< p.nmc:
           echo "MC index ", i
           ctx.mcIdx = i
           let cands = ctx.drawCandidates(rnd)
           let limit = ctx.computeLimit(rnd, cands, limitKind)
           let cInSens = candsInSens(ctx, cands)
           results.add (limit, cInSens)
         # o.urite toString(results), '\0')
         echo "Bytes: ", w.wrLenSeq results)

  proc computeParallelLimits(ctx: Context, limitKind: LimitKind, nmc: int): seq[(float, int)] =
    let nJobs = countProcessors()
    var pp = initProcPool(limitsWorker, framesLenPfx, jobs = nJobs)

    var work = newSeq[ProcData]()
    for i in 0 ..< nJobs:
      work.add ProcData(id: i, nmc: nmc div nJobs)

    var limits = newSeq[tuple[limit: float, cInSens: int]]()
    var getRes = proc(s: MSlice) =
      var res: seq[tuple[limit: float, cInSens: int]]
      s.toSeq(res)
      limits.add res
    pp.evalOb work, getRes
    result = limits

  proc compSigmalLimitsSerial(ctx: Context, limitKind: LimitKind): seq[tuple[σ_s, σ_b, limit: float]] =
    var σ_pairs = newSeq[(float, float)]()
    var σVals = @[0.05, 0.1, 0.15, 0.2, 0.25, 0.3]
    for σ_s in σVals:
      σ_pairs.add (σ_s, σ_s)

    var rnd = wrap(initMersenneTwister(1234.uint32))
    for (σ_s, σ_b) in σ_pairs:
      ctx.σsb_sig = σ_s
      ctx.σsb_back = σ_b
      let res = ctx.monteCarloLimits(rnd, limitKind, nmc = 50)
      result.add (σ_s, σ_b, res)

const SanityPath = "/home/basti/org/Figs/statusAndProgress/limitSanityChecks/"

proc plotSignalOverBackground(ctx: Context, log: Logger, outfile: string) =
  ## creates a plot of the signal over background for each pixel on the chip.
  ## Uses a limit of 8.1e-23
  var ctx = ctx
  ctx.g_ae² = 8.1e-11 * 8.1e-11
  var xs = newSeq[float](256 * 256)
  var ys = newSeq[float](256 * 256)
  var sb = newSeq[float](256 * 256)
  let energy = 1.5.keV
  for y in 0 ..< 256:
    for x in 0 ..< 256:
      xs[y * 256 + x] = x.float
      ys[y * 256 + x] = y.float
      let xp = x.float / 256.0 * 14.0
      let yp = y.float / 256.0 * 14.0
      ## TODO: Turn it around, why?
      #sb[y * 256 + x] = ctx.expectedSignal(energy, (x: yp, y: xp)) / ctx.background(energy)
      let pos = (x: xp, y: yp)
      let back = ctx.background(energy, pos)
      let sig = ctx.expectedSignal(energy, pos)
      #echo "Sig: ", sig, " vs ", back
      sb[y * 256 + x] = ln(1 + sig / back)
  let df = toDf(xs, ys, sb)
  template low: untyped = 4.5 / 14.0 * 256.0
  template hih: untyped = 9.5 / 14.0 * 256.0
  #showBrowser(df)
  var customInferno = inferno()
  customInferno.colors[0] = 0 # transparent
  log.infos("Signal over background"):
    &"Maximum ln(1 + S/B) value: {sb.max} at {sb.argmax}"
    &"Saving plot: {outfile}"
  ggplot(df, aes("xs", "ys", fill = "sb")) +
    geom_raster() +
    xlim(0, 255) + ylim(0, 255) +
    scale_x_continuous() + scale_y_continuous() +
    scale_fill_gradient(customInferno) +
    geom_linerange(aes = aes(x = low(), yMin = low(), yMax = hih()), color = parseHex "FF0000") +
    geom_linerange(aes = aes(x = hih(), yMin = low(), yMax = hih()), color = parseHex "FF0000") +
    geom_linerange(aes = aes(y = low(), xMin = low(), xMax = hih()), color = parseHex "FF0000") +
    geom_linerange(aes = aes(y = hih(), xMin = low(), xMax = hih()), color = parseHex "FF0000") +
    #ggtitle("Signal / Background for E = 1.5 keV & g_ae = 8.1e-11") +
    ggtitle("ln(1 + S / B) for E = 1.5 keV & g_ae = 8.1e-11") +
    ggsave(outfile)

proc integrateSignalOverImage(ctx: Context, log: Logger) =
  ## integrate the signal contribution over the whole image to see if we recover
  ## the ~O(10) axion induced signals
  var ctx = ctx
  ctx.g_ae² = pow(8.1e-11, 2.0)

  log.infoHeader("Integrate signal over full chip")
  # flush the logger file to not duplicate output when logger called in multiproccessing context
  flushFile(cast[FileLogger](log).file)

  # now integrate over full area
  let energies = linspace(0.071, 9.999, 10).mapIt(it.keV) # cut to range valid in interpolation
  let eWidth = energies[1].keV - energies[0].keV
  let pix = 256 * 256
  let area = 1.4.cm * 1.4.cm
  let pixArea = area / pix
  type
    IntRes = object
      done: bool
      hadWork: bool
      integral: float
      intBack: float
      sumOfRT: float
      sumOfGold: float
      integralGold: float
      intBackGold: float
  proc integrateWorker(r, w: cint) =
    let i = open(r)
    var o = open(w, fmWrite)
    var energy: keV
    var res: IntRes
    while i.uRd(energy):
      res.hadWork = true
      res.sumOfRT = 0.0
      res.sumOfGold = 0.0
      for y in 0 ..< 256:
        for x in 0 ..< 256:
          let xp = x.float / 256.0 * 14.0
          let yp = y.float / 256.0 * 14.0
          let pos = (x: xp, y: yp)
          let sig = ctx.expectedSignal(energy, pos) * eWidth * pixArea
          let back = ctx.background(energy, pos) * eWidth * pixArea
          res.integral += sig
          res.intBack += back
          res.sumOfRT += ctx.raytraceSpl.eval(x.float, y.float)
          if xp in 4.5 .. 9.5 and yp in 4.5 .. 9.5:
            res.sumOfGold += ctx.raytraceSpl.eval(x.float, y.float)
            res.integralGold += sig
            res.intBackGold += back
      log.infosP("RT contributions at energy " & $energy, prefix = "\t", sep = "-"):
        &"Total sum of RT contribution @ energy = {res.sumOfRT}"
        &"Total sum of RT gold contribution = {res.sumOfGold}"
        &"Ratio = {res.sumOfGold / res.sumOfRT}"
      # only write one final result
      discard o.uWr(res)
    res.done = true
    discard o.uWr(res)

  var pp = initProcPool(integrateWorker, framesOb, jobs = 16, aux = sizeof IntRes)
  var intRes = newSeq[IntRes]()
  var readRes = proc(s: MSlice) =
    var res: IntRes
    s.toOb(res)
    intRes.add res
  pp.evalOb energies, readRes
  # filter to all results that contain useful information
  intRes = intRes.filterIt(it.done and it.hadWork)
  # fold all energies
  var foldRes: IntRes
  for res in intRes:
    foldRes.integral += res.integral
    foldRes.intBack += res.intBack
    foldRes.integralGold += res.integralGold
    foldRes.intBackGold += res.intBackGold

  log.infosNoHeader:
    &"Expected number of signals in total = {expRate(ctx)}"
    &"Total integral of signal: {foldRes.integral} (integrated over the whole chip!)"
    &"Total integral of background: {foldRes.intBack} (integrated over the whole chip!)"
    &"Total integral of signal: {foldRes.integralGold} (integrated over gold region!)"
    &"Total integral of background: {foldRes.intBackGold} (integrated over gold region!)"
    &"Normalization factor: {foldRes.integral / expRate(ctx)}"

proc plotSignalAtEnergy(ctx: Context, log: Logger, energy: keV, title, outfile: string) =
  ## Generate a plot of the signal component in units of `keV⁻¹•cm⁻²•s⁻¹` at the specified
  ## energy using a coupling constant of `g_ae = 8.1e-11`.
  var ctx = ctx
  ctx.g_ae² = pow(8.1e-11, 2.0)
  var xs = newSeqOfCap[int](256*256)
  var ys = newSeqOfCap[int](256*256)
  var zs = newSeqOfCap[float](256*256)
  log.infos("Plot signal @ energy : " & $energy):
    &"Computing signal at energy {energy}. Dividing out total background time of {ctx.totalBackgroundTime}"
  for y in 0 ..< 256:
    for x in 0 ..< 256:
      xs.add x
      ys.add y
      let xp = x.float / 256.0 * 14.0
      let yp = y.float / 256.0 * 14.0
      ## Note: actual signal is in keV⁻¹•cm⁻², i.e. integrated over time. Hence we divide out the background time
      let sig = ctx.expectedSignal(energy, (x: xp, y: yp)) / ctx.totalBackgroundTime.to(Second)
      doAssert typeof(sig) is keV⁻¹•cm⁻²•s⁻¹
      zs.add sig.float
  var customInferno = inferno()
  customInferno.colors[0] = 0 # transparent
  log.infosNoHeader:
    &"Saving plot: {outfile}"
  ggplot(toDf(xs, ys, zs), aes("xs", "ys", fill = "zs")) +
    geom_raster() +
    scale_fill_gradient(customInferno) +
    xlim(0, 256) + ylim(0, 256) +
    ggtitle(title) +
    ggsave(outfile)

proc plotSamplingTensor(ctx: Context,
                        log: Logger,
                        energyIdx: int,
                        outfile = "/tmp/test_tensor.pdf",
                        title = "",
                        yMax = 0.0) =
  let interp = ctx.interp
  let size = interp.coords.len^2
  var xs = newSeq[int](size)
  var ys = newSeq[int](size)
  var cs = newSeq[float](size)
  var idx = 0
  for yi, y in interp.coords:
    for xi, x in interp.coords:
      xs[idx] = x.toIdx
      ys[idx] = y.toIdx
      cs[idx] = interp.expCounts[yi, xi, energyIdx]
      inc idx
  template low: untyped = 4.5 / 14.0 * 256.0
  template hih: untyped = 9.5 / 14.0 * 256.0
  let df = toDf(xs, ys, cs)
  let offset = interp.xyOffset.toIdx
  log.infosNoHeader:
    &"Saving plot: {outfile}"
  ggplot(df, aes(x = f{`xs` - offset}, y = f{`ys` - offset}, fill = "cs")) +
    geom_raster() +
    geom_linerange(aes = aes(x = low(), yMin = low(), yMax = hih()), color = parseHex "FF0000") +
    geom_linerange(aes = aes(x = hih(), yMin = low(), yMax = hih()), color = parseHex "FF0000") +
    geom_linerange(aes = aes(y = low(), xMin = low(), xMax = hih()), color = parseHex "FF0000") +
    geom_linerange(aes = aes(y = hih(), xMin = low(), xMax = hih()), color = parseHex "FF0000") +
    scale_fill_continuous(scale = (low: 0.0, high: yMax)) +
    xlim(0, 255) + ylim(0, 255) +
    margin(top = 1.5) +
    ggtitle(title & &" at E = {interp.energies[energyIdx]} keV") +
    ggsave(outfile)

proc plotSamplingTensorEnergy(
    ctx: Context,
    log: Logger,
    outfile = "/tmp/test_tensor.pdf",
    title = "",
    yMax = 0.0
     ) =
  let interp = ctx.interp
  let size = interp.coords.len * interp.energies.len
  var xs = newSeq[int](size)
  var Es = newSeq[float](size)
  var cs = newSeq[float](size)
  var idx = 0
  let mid = interp.coords.len div 2
  for Ei, E in interp.energies:
    for xi, x in interp.coords:
      xs[idx] = x.toIdx
      Es[idx] = E
      cs[idx] = interp.expCounts[mid, xi, Ei]
      inc idx
  let df = toDf(xs, Es, cs)
  echo df
  let xyOffset = interp.xyOffset.toIdx
  let eOffset = interp.eOffset
  log.infosNoHeader:
    &"Saving plot: {outfile}"
  ggplot(df, aes(x = f{`xs` - xyOffset}, y = f{`Es` - eOffset}, fill = "cs")) +
    geom_raster() +
    scale_x_continuous() + scale_y_continuous() +
    scale_fill_continuous(scale = (low: 0.0, high: yMax)) +
    xlim(0, 255) +
    ggtitle(title) +
    ggsave(outfile)

proc likelihoodScan(ctx: Context, log: Logger,
                    cands: seq[Candidate],
                    g_aeMax: float, num: int,
                   ): DataFrame =
  ## Computes a trivial likelihood scan for the given `ctx` and `cands`
  ## in the range of `0.0` to `g_aeMax` with `num` elements.
  ## Note: when using all systematic uncertainties, this will be rather slow!
  ## Only meant for sanity check plots.
  let t0 = getMonoTime()
  doAssert (1.0 - ctx.g_aγ² / (1e-12*1e-12)) < 1e-6, " was " & $(1.0 - ctx.g_aγ² / (1e-12*1e-12))
  let g_aes = linspace(0.0, g_aeMax, 100)
  var Ls = newSeq[float](100)
  for i, c in g_aes:
    Ls[i] = ctx.evalAt(cands, c)
  result = toDf(g_aes, Ls)
  let t1 = getMonoTime()
  log.infosP(header = "", prefix = "", sep = ""):
    &"Likelihood scan to {g_aeMax} with systematics {ctx.systematics.pretty()} took {t1 - t0}"

proc plotCandsLikelihood(ctx: Context, log: Logger,
                         cands: seq[Candidate],
                         chainDf: DataFrame,
                         g_aeMax: float, # maximum g_ae²
                         outfile, title: string) =
  ## Creates a plot of the likelihood space against g_ae² for the case no or few
  ## candidates in the sensitive region. Without candidates we expect a pure exponential decay
  ## due to the `exp(-R_T)` term. For few candidates that term should still dominate towards larger
  ## couplings.
  ##
  doAssert ctx.uncertainty == ukCertain
  doAssert ctx.uncertaintyPosition == puCertain
  let dfScan = ctx.likelihoodScan(log, cands, g_aeMax, 100)

  ## XXX: should we also plot the computed limit here?
  if chainDf.len == 0:
    log.infosNoHeader:
      &"Saving plot: {outfile}"
    ggplot(dfScan, aes("g_aes", "Ls")) +
      geom_line() +
      margin(top = 2.0) +
      xlab("g_ae²") +
      ggtitle(title) +
      ggsave(outfile)
  else:
    # plot both the MCMC histogram as well as the likelihood from a scan
    let nBins = 50
    let (hist, bins) = histogram(chainDf["gs", float].toSeq1D, bins = nBins)
    let hMax = hist.max
    let Lmax = dfScan["Ls", float].max
    let dfA = dfScan
      .mutate(f{"Ls" ~ `Ls` / Lmax * hMax})
    log.infosNoHeader:
      &"Saving plot: {outfile}"
    ggplot(toDf(bins, hist), aes("bins", "hist")) +
      geom_histogram(stat = "identity") +
      geom_line(data = dfA, aes = aes("g_aes", "Ls"), color = "yellow") +
      margin(top = 2.0) +
      xlab("g_ae²") +
      ggtitle(title) +
      ggsave(outfile)

proc plotCompareSystLikelihood(log: Logger,
                               dfScan, dfMCMC: DataFrame,
                               outfile, title: string) =
  ## generates a comparison plot of the linear scans (corresponding to differernt
  ## sig/back `σ` values) stored in `dfScan` (for a linear scan in `g_ae`) and for
  ## an MCMC.
  # first comptue histograms of `dfMCMC` cases in order to be able to normalize
  # the dfScan Ls
  var dfH = newDataFrame()
  var hMax = 0
  for (tup, subDf) in groups(dfMCMC.group_by("σ")):
    let nBins = 50
    let (hist, bins) = histogram(subDf["gs", float].toSeq1D, bins = nBins)
    hMax = max(hist.max, hMax)
    let σ = tup[0][1]
    dfH.add toDf({"g_aes" : bins[0 ..< bins.high], "Ls" : hist, "σ" : σ})
  echo dfH.pretty(-1)
  log.infosNoHeader:
    &"Saving plot: {outfile}"
  ggplot(dfScan, aes("g_aes", y = f{`Ls` / `Ls`.max * hMax}, color = factor("σ"))) +
    geom_line() +
    geom_histogram(
      data = dfH, stat = "identity", position = "identity", hdKind = hdOutline,
      fillColor = color(0.0, 0.0, 0.0, 0.0), lineWidth = 1.5) +
    margin(top = 2.0) +
    ggtitle(title) +
    ggsave(outfile)

proc plotCandsSigOverBack(ctx: Context, log: Logger, cands: seq[Candidate], outfile, title: string) =
  ## creates a plot of the candidates and the associated signal/background as color
  ## for each candidate (at g_ae = 8.1e-11, g_aγ = 1e-12 GeV⁻¹)
  var ctx = ctx
  # use a fixed g_ae² for the computation here
  ctx.g_ae² = pow(8.1e-11, 2.0)
  var sb = newSeq[float]()
  for c in cands:
    let sig = ctx.expectedSignal(c.energy, c.pos)
    sb.add ln(1 + sig / ctx.background(c.energy, c.pos))
  let df = toDf({ "xs" : cands.mapIt(it.pos.x.float),
                  "ys" : cands.mapIt(it.pos.y.float),
                  "sb" : sb })
  log.infosNoHeader:
    &"Saving plot: {outfile}"
  ggplot(df, aes("xs", "ys", color = "sb")) +
    geom_point() +
    margin(top = 2.0) +
    ggtitle(title) +
    ggsave(outfile)

proc plotBackgroundRateFromInterpolation(ctx: Context, log: Logger, outfile, title: string) =
  let minP = 4.5.toIdx
  let maxP = 9.5.toIdx
  let coords = linspace(minP, maxP, maxP - minP + 1)
  let energies = arange(0.0, 12.0, 0.2).mapIt(it.keV)
  var rates = newSeqOfCap[float](energies.len)
  var meanRate = 0.0.keV⁻¹•cm⁻²•s⁻¹
  ## XXX: turn this into propool usage for more bins?
  ## Well, number of bins for now is fine, but having a smooth representation would be useful for
  ## the fact that indeed the interpolation "smears out" the background somewhat!
  for E in energies:
    var sumRate = 0.0.keV⁻¹•cm⁻²•s⁻¹
    for y in coords:
      for x in coords:
        sumRate += ctx.background(E, (x: x.toInch(), y: y.toInch())) / ctx.totalTrackingTime.to(s)
    let R = sumRate / ((coords.len^2).float)
    rates.add R.float
    echo "Rate at energy ", E, " is = ", R
    meanRate += R
  meanRate /= energies.len.float
  static: echo type(energies)
  let eFloat = energies.mapIt(it.float)
  let df = toDf({"energies" : eFloat, "rates" : rates})
  echo "DF : ", df
  log.infosNoHeader:
    &"Mean background rate from interpolation in gold region (0-12 keV): {meanRate} at energy range {ctx.interp.energyRange}"
    &"\tand interpolation radius & sigma, R = {ctx.interp.radius}, σ = {ctx.interp.sigma}"
    &"Saving plot: {outfile}"
  ggplot(df, aes("energies", "rates")) +
    geom_histogram(stat = "identity", hdKind = hdOutline) +
    margin(top = 2.0) +
    ggtitle(title) +
    ggsave(outfile)

proc sanityCheckDetectionEff(ctx: Context, log: Logger) =
  ## Generates plots to sanity check the behavior of the detection efficiency related
  ## factors.

  ## XXX: include the following plot before the here generated
  # "/home/basti/org/Figs/statusAndProgress/detector/detection_efficiency.pdf"
  ## XXX: think about raytracer & its usage of the effective area. What does the now implemented
  ## efficiency imply for our usage of the data? If we in the future ignore the effect of the
  ## effective area in this code here, then do we properly take it into account? The effective
  ## area causes an effective loss and not a distortion after all. So by normalizing it, we take
  ## that effect out.... Do we need to create a raytracing image with *only* the effect of things
  ## that determine effective area?

  let energies = linspace(0.0, 10.0, 1000)
  let eff = energies.mapIt(ctx.detectionEff(it.keV).float)
  let averageEff = simpson(eff, energies) / (energies.max - energies.min)
  let e2 = linspace(0.5, 4.0, 1000)
  let eff2 = e2.mapIt(ctx.detectionEff(it.keV).float)
  let averageEffto4 = simpson(eff2, e2) / (e2.max - e2.min)
  let maxEff = eff.max
  let maxEffEnergy = energies[eff.find(maxEff)]
  log.infos("Detection efficiency"):
    &"Maximum detection efficiency = {maxEff} at energy = {maxEffEnergy.keV}"
    &"Average detection efficiency (0-10 keV) = {averageEff}"
    &"Average detection efficiency (0.5-4 keV) = {averageEffto4}"

  const coupling = 8.1e-11
  ctx.g_ae² = coupling * coupling
  let df = toDf({ "Energy [keV]" : energies,
                  "Efficiency [%]" : eff,
                  "Axion flux [keV⁻¹]" : energies.mapIt(ctx.axionFlux(it.keV).float) })
    .gather(["Efficiency [%]", "Axion flux [keV⁻¹]"], "key", "value")
  let sanityPlotPath = SanityPath / "sanity_detection_eff.pdf"
  log.infosNoHeader:
    &"Saving plot: {sanityPlotPath}"
  ggplot(df, aes("Energy [keV]", "value")) +
    facet_wrap("key", scales = "free") +
    geom_line() +
    margin(top = 2.0, bottom = 0.5) +
    xlab(margin = -0.25) +
    facetMargin(0.6) +
    ggtitle(&"Detection efficiency & axion flux (@ g_ae² = {coupling}²) in keV⁻¹ integrated over bore & tracking time.\n" &
            &"P_a↦γ: {conversionProbability().float:.3e}") +
    ggsave(sanityPlotPath, width = 1000, height = 480)

proc sanityCheckBackground(ctx: Context, log: Logger) =
  ## Generates sanity checks related to the background component

  proc rate(num: int, totalTime: Hour, area: cm²): cm⁻²•s⁻¹ =
    ## Computes the background rate over the whole chip simply based on total time
    ## chip area and number of clusters.
    result = num.float / (totalTime.to(Second) * area)

  proc filterGold(df: DataFrame): DataFrame =
    ## Filter the DF to the gold region
    result = df.filter(f{`centerX` >= 4.5 and `centerX` <= 9.5 and
                         `centerY` >= 4.5 and `centerY` <= 9.5})

  let ratio = ctx.totalBackgroundTime / ctx.totalTrackingTime
  # 3. background rate over whole chip in cm⁻¹•s⁻¹
  let intRateChip = rate(ctx.backgroundDf.len, ctx.totalBackgroundTime, 1.4.cm * 1.4.cm)
  # compute integrated background rate rate in gold region
  let intRateGold = rate(ctx.backgroundDf.filterGold.len,
                         ctx.totalBackgroundTime,
                         0.5.cm * 0.5.cm)

  # read data files without removing noisy pixels
  let dfNoise = readFiles(ctx.filePath, ctx.files, NoiseFilter())

  log.infos("Background"):
    &"Number of background clusters = {ctx.backgroundDf.len}"
    &"Number of background clusters including noisy pixels = {dfNoise.len}"
    # 2. total background time
    &"Total background time = {ctx.totalBackgroundTime}"
    &"Ratio of background to tracking time = {ratio}"
    &"Expected number of clusters in tracking time = {ctx.backgroundDf.len.float / ratio}"
    &"Background rate over full chip = {intRateChip}"
    &"Background rate over full chip per keV = {intRateChip / 12.keV}"
    &"Pixels removed as noisy pixels: {ctx.noiseFilter.pixels}"
    &"\tNumber of pixels removed as noisy pixels: {ctx.noiseFilter.pixels.len}"
    &"\tPercentage of total pixels: {ctx.noiseFilter.pixels.len.float / (256 * 256) * 100} %"
    &"\tin input files: {$ctx.noiseFilter.fnames}"
    &"Background rate in gold region = {intRateGold}"
    &"Background rate in gold region per keV = {intRateGold / 12.keV}"

  # plot of background clusters
  proc plotClusters(df: DataFrame, fname, suffix: string) =
    let clusterPlotPath = SanityPath / fname
    log.infosNoHeader:
      &"Saving plot: {clusterPlotPath}"
    ggplot(df, aes("centerX", "centerY", color = "Energy")) +
      geom_point(size = 1.0, alpha = 0.9) +
      ggtitle("Background <12 keV, # clusters = " & $df.len & suffix) +
      ggsave(clusterPlotPath)
  plotClusters(ctx.backgroundDf, "background_clusters.pdf", ". noisy pixels filtered")
  plotClusters(dfNoise, "background_clusters_including_noisy_pixels.pdf", ". noisy pixels *not* filtered")

  # plot of background rate in gold region
  # compute the weight of each cluster
  let weight = 1.0 / (ctx.totalBackgroundTime.to(Second) * 0.5.cm * 0.5.cm * 0.2.keV)
  when typeof(weight) isnot keV⁻¹•cm⁻²•s⁻¹:
    error("Type of `weight` is not `keV⁻¹•cm⁻²•s⁻¹`, but " & $typeof(weight))
  doAssert typeof(weight) is keV⁻¹•cm⁻²•s⁻¹, "was: " & $typeof(weight)
  ## Note: bin width of 0.2 keV is the typical width we use in `plotBackgroundRate.nim`.
  ## The `weight` is the correct weight needed to get the correct scaling as we would in
  ## `plotBackgroundRate.nim` as well.
  let backgroundRatePath = SanityPath / "background_rate_gold.pdf"
  log.infosNoHeader:
    &"Saving plot: {backgroundRatePath}"
  ggplot(ctx.backgroundDf.filterGold, aes("Energy")) +
    geom_histogram(aes = aes(weight = f{weight.float}), binWidth = 0.2) +
    ggtitle("Background rate in gold region. Integrated = " & pretty(intRateGold / 12.0.keV, 3, true)) +
    ggsave(backgroundRatePath)

  # now call `plotBackgroundRate` using `shell` (*must be in PATH*!)
  let files = ctx.files.mapIt(ctx.filePath / it).join(" ")
  log.infosNoHeader:
    "Calling `plotBackgroundRate` to generate 'correct' background rate plot from input data"
  shell:
    plotBackgroundRate ($files) --combName FromLimit --combYear 2018 --region crGold --outpath ($SanityPath) --outfile background_rate_from_limit_call.pdf

proc sanityCheckRaytracingImage(ctx: Context, log: Logger) =
  ## Generates sanity checks related to the raytracing component
  ##
  ## Still missing:
  ## - integration of raytracing image
  ## - ?
  log.infoHeader("Raytracing checks")

  block NoWindow:
    ctx.plotRaytracingImage(log,
                            SanityPath / "axion_image_limit_calc_no_window_no_theta.pdf",
                            "Axion image as used in limit calculation without window strongback",
                            ignoreWindow = true)
  block NoTheta:
    ctx.plotRaytracingImage(log,
                            SanityPath / "axion_image_limit_calc_no_theta.pdf",
                            "Axion image as used in limit calculation with window strongback")
  block ThetaMoved:
    ctx.θ_x = 0.6
    ctx.θ_y = 0.6
    log.infosNoHeader:
      &"Raytracing image at θ_x = θ_y = {ctx.θ_x}"
    ## XXX: investigate why the strongback doesn't show up in bottom left
    ctx.plotRaytracingImage(log,
                            SanityPath / "axion_image_limit_calc_theta_0_6.pdf",
                            "Axion image as used in limit calc w/ window strongback & θx,y = 0.6")
    ctx.θ_x = 0.0
    ctx.θ_y = 0.0

proc sanityCheckBackgroundInterpolation(ctx: Context, log: Logger) =
  ## creates plots to verify the background interpolation
  # 1. plot raw interpolation without corrections at 1 keV

  log.infos("Background interpolation"):
    &"Radius for background interpolation in x/y: {ctx.interp.radius}"
    &"Clusters are weighted with normal distribution dependent on distance using σ: {ctx.interp.sigma}"
    &"Energy range for background interpolation in x/y: {ctx.interp.energyRange}"
    &"Energy range is a fixed interval ± given value without weighting"

  let interp = ctx.interp
  proc sliceAt(energy: keV) =
    # raw interpolation, no corrections or normalization
    let energy = energy # for `&` strformat to work
    let Estr = pretty(energy, 3, short = true)
    log.infosP(&"Background interpolation slice @ {energy.keV}", prefix = "\t", sep = "-"):
      &"Generating background interpolation slices at energy: "
    proc plotRaw(yMax: float) =
      let outf = SanityPath / &"raw_interpolation_at_{energy.float}keV_ymax_{yMax}.pdf"
      log.infosP("", prefix = "\t", sep = ""):
        &"Saving plot: {outf}"
      plotEnergySlice(
          outfile = outf,
          title = &"Raw background interpolation at {Estr}",
          yMax = yMax):
        t[y, x] = interp.kd.query_ball_point([x.float, y.float, energy.float].toTensor,
                                           radius = interp.radius,
                                           metric = CustomMetric)
          .compValue()
    plotRaw(15.0) # with a low limit for the center region
    plotRaw(0.0)  # automatic limit
    # interpolation with edge cutoff
    proc plotEdgeCorrect(yMax: float) =
      let outf = SanityPath / &"interpolation_edge_correct_at_{energy.float}keV_ymax_{yMax}.pdf"
      log.infosP("", prefix = "\t", sep = ""):
        &"Saving plot: {outf}"
      plotEnergySlice(
          outfile = outf,
          title = &"Background interpolation w/ edge correction at {Estr}",
          yMax = yMax):
        t[y, x] = interp.kd.query_ball_point([x.float, y.float, energy.float].toTensor,
                                           radius = interp.radius,
                                           metric = CustomMetric)
          .compValue()
          .correctEdgeCutoff(interp.radius, x, y)
    plotEdgeCorrect(15.0) # low limit for visible center
    plotEdgeCorrect(0.0)  # automatic limit
    # interpolation with edge cutoff and normalization
    proc plotNormed(yMax: float) =
      let outf = SanityPath / &"normalized_interpolation_at_{energy.float}keV_ymax_{yMax}.pdf"
      log.infosP("", prefix = "\t", sep = ""):
        &"Saving plot: {outf}"
      plotEnergySlice(
          outfile = outf,
          title = &"Background rate from interpolation w/ normalization & edge correction at {Estr} in keV⁻¹·cm⁻²·s⁻¹",
          yMax = yMax):
        t[y, x] = interp.kd.query_ball_point([x.float, y.float, energy.float].toTensor,
                                             radius = interp.radius,
                                             metric = CustomMetric)
          .compValue()
          .correctEdgeCutoff(interp.radius, x, y)
          .normalizeValue(interp.radius, interp.energyRange, interp.backgroundTime)
          .float
    plotNormed(5e-5) # low limit for center region (units of keV⁻¹•cm⁻²•s⁻¹)
    plotNormed(0.0)
  sliceAt(0.5.keV)
  sliceAt(1.0.keV)
  sliceAt(3.0.keV)
  sliceAt(8.0.keV)

  # finally compute background rate from interpolation
  ctx.plotBackgroundRateFromInterpolation(
    log,
    SanityPath / "background_rate_in_gold_region_from_interpolation.pdf",
    &"Background rate in gold region computed from interpolation, with energy range = {ctx.interp.energyRange}"
  )

proc sanityCheckBackgroundSampling(ctx: Context, log: Logger) =
  ## creates plots to verify the background sampling. That is the grid in which
  ## we draw, computed from the background interpolation.
  # 1. sum up contents of `expCounts` to count total number of "expected" background events
  # and compare to number from background interpolation
  let ratio = ctx.totalBackgroundTime / ctx.totalTrackingTime
  log.infos("Candidate sampling"):
    &"Sum of background events from candidate sampling grid (`expCounts`) = {ctx.interp.expCounts.sum()}"
    &"Expected number from background data (normalized to tracking time) = {ctx.backgroundDf.len.float / ratio}"
    &"Number of grid cells for x/y: {ctx.interp.nxy}"
    &"Number of grid cells for E: {ctx.interp.nE}"
    &"Offset in x/y to center points at: {ctx.interp.xyOffset}"
    &"Offset in E to center points at: {ctx.interp.eOffset}"
    &"Coordinates in x/y: {ctx.interp.coords}"
    &"Coordinates in E: {ctx.interp.energies}"
    &"Sampling is smeared within grid volumes"

  ## XXX: Once we have added the noisy pixel filtering to a further stage / have both as DFs in the context
  ## turn the expected clusters into a proper test (at least an assertion)

  # 2. create x/y plots at different energies
  proc plotIndex(idx: int) =
    ctx.plotSamplingTensor(
      log,
      energyIdx = idx,
      SanityPath / &"candidate_sampling_grid_index_{idx}.pdf",
      "Grid for MC candidate sampling, x/y"
    )
  plotIndex(2)  # 1.25 keV
  plotIndex(5)  # 2.75 keV
  plotIndex(16) # 8.0 keV
  # 3. plot slice of x/E at y~=128
  ctx.plotSamplingTensorEnergy(
    log,
    SanityPath / &"candidate_sampling_grid_vs_energy.pdf",
    "Grid for MC candidate sampling, x/E at y~=128"
  )

  # 4. generate 3 different candidate samplings and plot them
  var rnd = wrap(initMersenneTwister(42 + 1337))
  for i in 0 ..< 3:
    let cands = ctx.drawCandidates(rnd)
    let outfile = SanityPath / &"example_candidates_{i}.pdf"
    log.infosNoHeader:
      &"Candidates sample # {i} contains {cands.len} candidates"
      &"Saving plot: {outfile}"
    plotCandidates(
      cands,
      outfile = outfile,
      title = "Candidates sampled from gridded background interp (incl. smearing in volume), " & $i &
        ", # clusters " & $cands.len,
      topMargin = 2.0
    )

proc sanityCheckSignal(ctx: Context, log: Logger) =
  ## Generates sanity checks related to the signal component

  # 1. plot the signal at 1 keV energy (scales ~smoothly and in area constant for changing
  # energy).
  ctx.plotSignalAtEnergy(
    log, 1.0.keV,
    "Signal in keV⁻¹•cm⁻²•s⁻¹ at g_ae = 8.1e-11 at E = 1 keV",
    SanityPath / "signal_rate_1keV_over_chip.pdf"
  )

  # 2. integrate signal over the background hypothesis at g_ae = 8.1e-11 to check amount of
  # collected signal
  ctx.integrateSignalOverImage(log)

  # 3. plot signal over background at specific coupling constant
  ctx.plotSignalOverBackground(
    log,
    SanityPath / "signal_over_background_at_1_5keV_8_1e11.pdf"
  )

proc sanityCheckLikelihoodNoSystematics(ctx: Context, log: Logger) =
  ## generates plots to cross check the behavior of the likelihood
  ## also serves as a way to cross check MCMC against analytical / numerical integration approach
  ##
  ## Only generates plots related to a `Context` without any systematics.
  # setup an RNG
  var rnd = wrap(initMersenneTwister(0xaffe))

  var candsFewSignals: seq[Candidate]
  var candsManySignals: seq[Candidate]
  block OnlyAnalytical:
    # 1. likelihood scan w/o candidates w/o uncertainties (MCMC & analytical?)
    ctx.plotCandsLikelihood(
      log,
      newSeq[Candidate](), # no candidates
      newDataFrame(), # no MCMC dataframe
      1e-20,
      SanityPath / "likelihood_no_candidates.pdf",
      "Likelihood behavior without candidates, pure exponential decay " &
        &"exp(-R_T) at g_aγ = {sqrt(ctx.g_aγ²)} (no systematics)"
    )

    var cands: seq[Candidate]

    # 2a. draw a set of candidates, such that few in signal region
    cands = ctx.drawCandidates(rnd)
    while ctx.candsInSens(cands) > 1: # draw until we have less or equal 1 candidate in sens region
      cands = ctx.drawCandidates(rnd)
    candsFewSignals = cands
    # 2b. plot of cands in sensitive region (i.e. plot of candidates with color being s/b)
    ctx.plotCandsSigOverBack(
      log,
      cands,
      SanityPath / "candidates_signal_over_background_few_sens.pdf",
      "ln(1 + s/b) for case with <= 1 candidates in sens. region. " &
        &"g_ae = {sqrt(ctx.g_ae²)}, g_aγ = {sqrt(ctx.g_aγ²)} (no systematics)"
    )
    # 2c. likelihood scan w/ set of candidates (few in signal region)
    ctx.plotCandsLikelihood(
      log,
      cands,
      newDataFrame(), # no MCMC dataframe
      1e-20,
      SanityPath / "likelihood_few_cands_in_sens_region.pdf",
      "Likelihood behavior with few cands. in sens. region. At larger g_ae² dominated by " &
        &"exp(-R_T). g_aγ = {sqrt(ctx.g_aγ²)} (no systematics)"
    )

    # now repeat with multiple >4 candidates in sensitive region
    # 3a. draw a set of candidates, such that few in signal region
    while ctx.candsInSens(cands) <= 4: # draw until we have more than 4 in sens region
      cands = ctx.drawCandidates(rnd)
    candsManySignals = cands
    # 3b. plot of cands in sensitive region (i.e. plot of candidates with color being s/b)
    ctx.plotCandsSigOverBack(
      log,
      cands,
      SanityPath / "candidates_signal_over_background_many_sens.pdf",
      "ln(1 + s/b) for case with > 4 candidates in sens. region. " &
        &"g_ae = {sqrt(ctx.g_ae²)}, g_aγ = {sqrt(ctx.g_aγ²)} (no systematics)"
    )
    # 3c. likelihood scan w/ set of candidates (few in signal region)
    ctx.plotCandsLikelihood(
      log,
      cands,
      newDataFrame(), # no MCMC dataframe
      3e-20,
      SanityPath / "likelihood_many_cands_in_sens_region.pdf",
      "Likelihood behavior with many cands. in sens. region. At larger g_ae² dominated by " &
        &"exp(-R_T). g_aγ = {sqrt(ctx.g_aγ²)} (no systematics)"
    )

  block MCMC:
    # similar to above (in terms of likelihood scan), but now also including MCMC
    # MCMC for few candidates in sensitive region
    var chain: seq[seq[float]]
    var df: DataFrame
    chain = ctx.build_MH_chain(rnd, candsFewSignals)
    df = chain.extractFromChain(@[])
    ctx.plotCandsLikelihood(
      log,
      candsFewSignals,
      df,
      1.2e-20,
      SanityPath / "likelihood_with_mcmc_few_cands_in_sens_region.pdf",
      "Likelihood, few cands. in sens. region w/ MCMC histo. MCMC & scan agree. " &
        &"g_aγ = {sqrt(ctx.g_aγ²)} (no systematics)"
    )

    # MCMC for many candidates in sensitive region
    chain = ctx.build_MH_chain(rnd, candsManySignals)
    df = chain.extractFromChain(@[])
    ctx.plotCandsLikelihood(
      log,
      candsManySignals,
      df,
      3e-20,
      SanityPath / "likelihood_with_mcmc_many_cands_in_sens_region.pdf",
      "Likelihood, many cands. in sens. region w/ MCMC histo. MCMC & scan agree. " &
        &"g_aγ = {sqrt(ctx.g_aγ²)} (no systematics)"
    )

proc plotLikelihoodCurves(ctx: Context, candidates: seq[Candidate],
                          prefix: string) =
  ## Plots the likelihood curves at a specific coupling constant in θ
  let s_tot = expRate(ctx)
  var cSigBack = newSeq[(float, float)](candidates.len)
  for i, c in candidates:
    cSigBack[i] = (ctx.expectedSignal(c.energy, c.pos).float,
                   ctx.background(c.energy, c.pos).float)
  case ctx.uncertainty
  of ukUncertain:
    let σ_b = ctx.σsb_back
    let σ_s = ctx.σsb_sig
    block θ_signal:
      proc likeBack(θ_b: float): float =
        proc likeSig(θ_s: float, nc: NumContext[float, float]): float =
          L(s_tot * (1 + θ_s),
            s_i * (1 + θ_s),
            b_i * (1 + θ_b),
            θ_s, σ_s,
            θ_b, σ_b)
        result = adaptiveGauss(likeSig, -10.0, 10.0)
      let θb = linspace(-0.99, 10.0, 1000)
      let df = toDf({"θb" : θb, "L" : θb.mapIt(likeBack(it))})
        .filter(f{`L` > 1e-6})
      #df.showBrowser()
      ggplot(df, aes("θb", "L")) +
        geom_line() +
        scale_y_log10() +
        ggtitle("L(θ_s) = ∫_{-∞}^∞ L(θ_s, θ_b) dθ_b, at σ_s = " & &"{ctx.σsb_sig}") +
        ggsave(prefix & "θb_integrated_θs.pdf")
    block θ_background:
      proc likeSig(θ_s: float): float =
        proc likeBack(θ_b: float, nc: NumContext[float, float]): float =
          L(s_tot * (1 + θ_s),
            s_i * (1 + θ_s),
            b_i * (1 + θ_b),
            θ_s, σ_s,
            θ_b, σ_b)
        result = adaptiveGauss(likeBack, -0.8, 10.0)
      let θs = linspace(-1.5, 1.5, 1000)
      var df = toDf({"θs" : θs, "L" : θs.mapIt(likeSig(it))})
      df = df.filter(f{`L` > 0.0})
      let logL = df["L", float].map_inline(log10(x))
      let ymax = logL.max.ceil
      let yRealMin = logL.min.floor
      let ymin = if abs(yRealMin - ymax) > 20: ymax - 20.0
                 else: yRealMin
      # let xlim = (low: pow(10.0, ymin), high: pow(10.0, ymax))
      ggplot(df, aes("θs", "L")) +
        geom_line() +
        scale_y_log10() +
        ylim(ymin, ymax) +
        ggtitle("L(θ_b) = ∫_{-∞}^∞ L(θ_s, θ_b) dθ_s, at σ_b = " & &"{ctx.σsb_back}") +
        ggsave(prefix & "θs_integrated_θb.pdf")
  of ukUncertainSig:
    let σ_s = ctx.σs_sig
    proc likeSig(θ_s: float): float =
      L(s_tot * (1 + θ_s),
        s_i * (1 + θ_s),
        b_i,
        θ_s, σ_s,
        0.0, 0.0)
    let θs = linspace(-0.99, 10.0, 1000)
    let df = toDf({"θ" : θs, "L" : θs.mapIt(likeSig(it))})
      .filter(f{`L` > 1e-6})
    #df.showBrowser()
    ggplot(df, aes("θ", "L")) +
      geom_line() +
      scale_y_log10() +
      ggtitle(&"L(θ_s), at σ_s = {ctx.σs_sig}") +
      ggsave(prefix & "θs.pdf")
  of ukUncertainBack:
    let σ_b = ctx.σb_back
    proc likeBack(θ_b: float): float =
      L(s_tot,
        s_i,
        b_i * (1 + θ_b), # log-normal (but wrong): exp(b_i * (1 + θ_b)),
        0.0, 0.0,
        θ_b, σ_b)
    let θs = linspace(-0.98, 1.0, 1000)
    var df = toDf({"θ" : θs, "L" : θs.mapIt(likeBack(it))})
    echo df
    #df = df
    #  .filter(f{`L` > 1e-6})
    #echo df
    #df.showBrowser()
    ggplot(df, aes("θ", "L")) +
      geom_line() +
      scale_y_log10() +
      ggtitle(&"L(θ_b), at σ_b = {ctx.σb_back}") +
      ggsave(prefix & "θb.pdf")
  else:
    if ctx.uncertaintyPosition == puUncertain:
      when false: #block TX:
        let s_tot = expRate(ctx)
        proc likeX(θ_x: float): float =
          ctx.θ_x = θ_x
          proc likeY(θ_y: float, nc: NumContext[float, float]): float =
            ctx.θ_y = θ_y
            for i, c in candidates:
              cSigBack[i] = (ctx.expectedSignal(c.energy, c.pos).float,
                          ctx.background(c.energy, c.pos).float)
            L(s_tot,
              s_i,
              b_i,
              0.0, 0.0, # signal
              0.0, 0.0, # background
              θ_x, ctx.σ_p,
              θ_y, ctx.σ_p)
          result = adaptiveGauss(likeY, -1.0, 1.0, maxIntervals = 100)
        let θx = linspace(-1.0, 1.0, 1000)
        var df = toDf({"θ" : θx, "L" : θx.mapIt(likeX(it))})
        echo df
        df = df
          .filter(f{`L` > 1e-24})
        #echo df
        #df.showBrowser()
        ggplot(df, aes("θ", "L")) +
          geom_line() +
          scale_y_log10() +
          ggtitle(&"L(θ_x), at σ_p = {ctx.σ_p} integrated over θ_y") +
          ggsave(prefix & "θx.pdf")
      when false: #block TY:
        let s_tot = expRate(ctx)
        proc likeY(θ_y: float): float =
          ctx.θ_y = θ_y
          proc likeX(θ_x: float, nc: NumContext[float, float]): float =
            ctx.θ_x = θ_x
            for i, c in candidates:
              cSigBack[i] = (ctx.expectedSignal(c.energy, c.pos).float,
                             ctx.background(c.energy, c.pos).float)
            L(s_tot,
              s_i,
              b_i,
              0.0, 0.0, # signal
              0.0, 0.0, # background
              θ_x, ctx.σ_p,
              θ_y, ctx.σ_p)
          result = adaptiveGauss(likeX, -1.0, 1.0, maxIntervals = 100)
        let θy = linspace(-1.0, 1.0, 1000)
        var df = toDf({"θ" : θy, "L" : θy.mapIt(likeY(it))})
        echo df
        df = df
          .filter(f{`L` > 1e-24})
        #echo df
        #df.showBrowser()
        ggplot(df, aes("θ", "L")) +
          geom_line() +
          scale_y_log10() +
          ggtitle(&"L(θ_y), at σ_p = {ctx.σ_p} integrated over θ_x") +
          ggsave(prefix & "θy.pdf")
      block Test:
        let s_tot = expRate(ctx)
        var cSigBack = newSeq[(float, float)](candidates.len)
        let SQRT2 = sqrt(2.0)
        for i, c in candidates:
          let sig = ctx.detectionEff(c.energy) * ctx.axionFlux(c.energy) * conversionProbability()
          cSigBack[i] = (sig.float,
                      ctx.background(c.energy, c.pos).float)
        let σ_p = ctx.σ_p
        proc likeX(θ_x: float): float =
          ctx.θ_x = θ_x
          proc likeY(θ_y: float, nc: NumContext[float, float]): float =
            ctx.θ_y = θ_y
            result = exp(-s_tot)
            result *= exp(-pow(θ_x / (SQRT2 * σ_p), 2)) * exp(-pow(θ_y / (SQRT2 * σ_p), 2))
            for i in 0 ..< cSigBack.len:
              let (s_init, b_c) = cSigBack[i]
              if b_c.float != 0.0:
                let s_c = (s_init * ctx.raytracing(candidates[i].pos)).float
                result *= (1 + s_c / b_c)
          result = simpson(likeY, -1.0, 1.0)
        let θx = linspace(-1.0, 1.0, 1000)
        var df = toDf({"θ" : θx, "L" : θx.mapIt(likeX(it))})
        echo df
        df = df
          .filter(f{`L` > 1e-24})
        ggplot(df, aes("θ", "L")) +
          geom_line() +
          scale_y_log10() +
          ggtitle(&"L(θ_x), at σ_p = {ctx.σ_p} integrated over θ_y") +
          ggsave(prefix & "θx_alternative.pdf")
      block TestXY:
        let s_tot = expRate(ctx)
        var cSigBack = newSeq[(float, float)](candidates.len)
        let SQRT2 = sqrt(2.0)
        for i, c in candidates:
          let sig = ctx.detectionEff(c.energy) * ctx.axionFlux(c.energy) * conversionProbability()
          cSigBack[i] = (sig.float,
                      ctx.background(c.energy, c.pos).float)
        let σ_p = ctx.σ_p

        proc like(θ_x, θ_y: float): float =
          ctx.θ_x = θ_x
          ctx.θ_y = θ_y
          result = exp(-s_tot)
          result *= exp(-pow(θ_x / (SQRT2 * σ_p), 2)) * exp(-pow(θ_y / (SQRT2 * σ_p), 2))
          for i in 0 ..< cSigBack.len:
            let (s_init, b_c) = cSigBack[i]
            if b_c.float != 0.0:
              let s_c = (s_init * ctx.raytracing(candidates[i].pos)).float
              result *= (1 + s_c / b_c)
        let θs = linspace(-1.0, 1.0, 1000)
        var θx = newSeq[float]()
        var θy = newSeq[float]()
        var val = newSeq[float]()
        for x in θs:
          for y in θs:
            θx.add -x
            θy.add -y
            val.add like(x, y)
        var df = toDf({"θx" : θx, "θy" : θy, "L" : val})
        echo df
        #df = df
        #  .filter(f{`L` > 1e-24})
        var customInferno = inferno()
        customInferno.colors[0] = 0 # transparent
        ggplot(df, aes("θx", "θy", fill = "L")) +
          geom_raster() +
          scale_fill_gradient(customInferno) +
          ggtitle(&"L(θ_x, θ_y), at σ_p = {ctx.σ_p}") +
          ggsave(prefix & "θx_θy.pdf")
    else:
      quit("not va")

proc calcSigBack(ctx: Context, rnd: var Random, log: Logger, cands: seq[Candidate], suffix: string) =
  ## given some candidates, go through calculation of likelihood for different
  ## σ, plot
  ## `suffix` corresponds to the name used in the filename & title, as
  ## well as the description for what the cutoff number is in terms of the candidates
  ## we sampled for.
  var dfScan = newDataFrame() # stores L for the scan
  var dfMCMC = newDataFrame() # stores the MCMC for each σ
  for σ in [0.0, 0.025, 0.05, 0.25]:
    let syst = initSystematics(σ_sig = σ, σ_back = σ)
    ctx.systematics = syst
    let maxVal = if suffix == "few": 1.2e-20
                 else: 3e-20
    var dfSLoc = ctx.likelihoodScan(log, cands, g_aeMax = maxVal, num = 100)
    dfSLoc["σ"] = σ
    dfScan.add dfSLoc
    ## XXX: ok I have to look at the MCMC chain plots
    let chain = ctx.build_MH_chain(rnd, cands)
    let names = if σ > 0.0: @["θs_s", "θs_b"] else: @[]
    var dfMLoc = chain.extractFromChain(names)
    dfMLoc["σ"] = σ
    if "θs_s" notin dfMLoc:
      dfMLoc["θs_s"] = 0.0; dfMLoc["θs_b"] = 0.0
    if σ > 0.0:
      # plot the mcmc lines for s & b
      ggplot(dfMLoc, aes("θs_s", "θs_b", color = "gs")) +
        geom_line(size = 0.5) + geom_point(size = 1.0, alpha = 0.1) +
        ggsave(SanityPath / &"mcmc_lines_thetas_sb_sigma_{σ}_{suffix}.png", width = 2400, height = 2000)
      # also plot L against θb
      ctx.g_ae² = 8.1e-11 * 8.1e-11
      plotLikelihoodCurves(ctx, cands, SanityPath / &"likelihood_sigma_{σ}_{suffix}")
    dfMCMC.add dfMLoc
  plotCompareSystLikelihood(
    log,
    dfScan, dfMCMC,
    SanityPath / &"likelihood_sig_back_sigma_compare_{suffix}_cands_in_sens_region.pdf",
    &"Likelihood behavior with {suffix} cands. in sens. region for different `σ` (S, B)" &
      &"g_aγ = {sqrt(ctx.g_aγ²)} (no systematics)"
  )

proc calcPosition(ctx: Context, rnd: var Random, log: Logger, cands: seq[Candidate], suffix: string) =
  ## given some candidates, go through calculation of likelihood for different
  ## σ_p (position uncertainty), plot
  ## `suffix` corresponds to the name used in the filename & title, as
  ## well as the description for what the cutoff number is in terms of the candidates
  ## we sampled for.
  var dfScan = newDataFrame() # stores L for the scan
  var dfMCMC = newDataFrame() # stores the MCMC for each σ
  for σ in [0.0, 0.025, 0.05, 0.25]:
    ## NOTE: the 0.25 case serves as a good reminder that the x singularity *can* still
    ## be a problem, even if we restrict that region of the space. Let's make those examples
    ## a good point to highlight then, that the singularity *can* play a role, but does not
    ## because our real systematics are so far away from this value that it precisely will
    ## *not* matter.
    let syst = initSystematics(σ_p = σ)
    ctx.systematics = syst
    let maxVal = if suffix == "few": 1.2e-20
                 else: 3e-20
    var dfSLoc = ctx.likelihoodScan(log, cands, g_aeMax = maxVal, num = 100)
    dfSLoc["σ"] = σ
    dfScan.add dfSLoc
    ## XXX: ok I have to look at the MCMC chain plots
    let chain = ctx.build_MH_chain(rnd, cands)
    let names = if σ > 0.0: @["θs_x", "θs_y"] else: @[]
    var dfMLoc = chain.extractFromChain(names)
    dfMLoc["σ"] = σ
    if "θs_x" notin dfMLoc:
      dfMLoc["θs_x"] = 0.0; dfMLoc["θs_y"] = 0.0
    if σ > 0.0:
      # plot the mcmc lines for s & b
      echo dfMLoc
      ggplot(dfMLoc, aes("θs_x", "θs_y", color = "gs")) +
        geom_line(size = 0.5) + geom_point(size = 1.0, alpha = 0.1) +
        ggsave(SanityPath / &"mcmc_lines_thetas_xy_sigma_{σ}_{suffix}.png", width = 2400, height = 2000)
      # also plot L against θb
      ctx.g_ae² = 8.1e-11 * 8.1e-11
      plotLikelihoodCurves(ctx, cands, SanityPath / &"likelihood_sigma_{σ}_{suffix}")

    dfMCMC.add dfMLoc
  plotCompareSystLikelihood(
    log,
    dfScan, dfMCMC,
    SanityPath / &"likelihood_x_y_sigma_compare_{suffix}_cands_in_sens_region.pdf",
    &"Likelihood behavior with {suffix} cands. in sens. region for different `σ` (x, y)" &
      &"g_aγ = {sqrt(ctx.g_aγ²)} (no systematics)"
  )

proc calcRealSystematics(ctx: Context, rnd: var Random, log: Logger,
                         cands: seq[Candidate], suffix: string) =
  ## given some candidates, go through calculation of likelihood for the real
  ## set of systematics that we use for our actual limit.
  ## `suffix` corresponds to the name used in the filename & title, as
  ## well as the description for what the cutoff number is in terms of the candidates
  ## we sampled for.
  let syst = initSystematics(
    σ_sig = 0.04692492913207222, # from sqrt(squared sum) of signal uncertainties
    σ_back = 0.002821014576353691,#, # from sqrt(square sum) of back uncertainties
    σ_p = 0.05 # from sqrt(squared sum of x / 7) position uncertainties
  )
  ctx.systematics = syst
  let maxVal = if suffix == "few": 1.2e-20
               else: 3e-20
  var dfScan = ctx.likelihoodScan(
    log, cands, g_aeMax = maxVal, num = 100
  )
  dfScan["σ"] = "real"
  ## XXX: ok I have to look at the MCMC chain plots
  let chain = ctx.build_MH_chain(rnd, cands)
  let names = @["θs_s", "θs_b", "θs_x", "θs_y"]
  var dfMCMC = chain.extractFromChain(names)
  dfMCMC["σ"] = "real"
  # plot the mcmc lines for s & b
  ggplot(dfMCMC, aes("θs_s", "θs_b", color = "gs")) +
    geom_line(size = 0.5) + geom_point(size = 1.0, alpha = 0.1) +
    ggsave(SanityPath / &"mcmc_lines_thetas_sb_real_syst_{suffix}.png", width = 2400, height = 2000)
  ggplot(dfMCMC, aes("θs_x", "θs_y", color = "gs")) +
    geom_line(size = 0.5) + geom_point(size = 1.0, alpha = 0.1) +
    ggsave(SanityPath / &"mcmc_lines_thetas_xy_real_syst_{suffix}.png", width = 2400, height = 2000)

  # also plot L against θb
  ctx.g_ae² = 8.1e-11 * 8.1e-11
  plotLikelihoodCurves(ctx, cands, SanityPath / &"likelihood_real_syst_{suffix}")

  plotCompareSystLikelihood(
    log,
    dfScan, dfMCMC,
    SanityPath / &"likelihood_real_syst_compare_{suffix}_cands_in_sens_region.pdf",
    &"Likelihood behavior with {suffix} cands. in sens. region for different `σ` (S, B)" &
      &"g_aγ = {sqrt(ctx.g_aγ²)} (no systematics)"
  )

proc sanityCheckLikelihoodSyst(ctx: Context, log: Logger) =
  ## generates plots to cross check the behavior of the likelihood
  ## also serves as a way to cross check MCMC against analytical / numerical integration approach
  ##
  ## `ctx` is the Context with systematics (only sig & back), while `ctxNoSyst` has no systematics
  ## at all (to compute behavior w/o syst)
  # setup an RNG
  var rnd = wrap(initMersenneTwister(0xaffe))
  # reset systematics for drawing of candidates
  ctx.systematics = initSystematics()

  var cands: seq[Candidate]
  # draw "few" candidates in sens region
  cands = ctx.drawCandidates(rnd)
  while ctx.candsInSens(cands) > 1: # draw until we have less or equal 1 candidate in sens region
    cands = ctx.drawCandidates(rnd)
  # compute things for signal / background nuisance parameter behavior
  ctx.calcSigBack(rnd, log, cands, "few")
  # compute things for position nuisance parameter
  ctx.calcPosition(rnd, log, cands, "few")
  # compute things for real systematics parameter
  ctx.calcRealSystematics(rnd, log, cands, "few")

  # reset systematics for drawing of candidates
  ctx.systematics = initSystematics()
  # draw "many" candidates in sens region
  cands = ctx.drawCandidates(rnd)
  while ctx.candsInSens(cands) <= 4: # draw until we have less or equal 1 candidate in sens region
    cands = ctx.drawCandidates(rnd)
  # compute things for signal / background nuisance parameter behavior
  ctx.calcSigBack(rnd, log, cands, "many")
  # compute things for position nuisacnce parameter
  ctx.calcPosition(rnd, log, cands, "many")
  # compute things for real systematics parameter
  ctx.calcRealSystematics(rnd, log, cands, "many")

  ## XXX: also plot the candidate clusters (sig / back & energy?)

proc sanityCheckSigmaLimits(ctx: Context, log: Logger,
                            limitKind: LimitKind,
                            nmc: int) =
  let expLimits = ctx.computeSigmaLimits(limitKind, nmc = nmc)
  #let expLimits = ctx.compSigmalLimitsSerial(limitKind)
  let df = toDf({ "σ_s" : expLimits.mapIt(it.σ_s),
                  "σ_b" : expLimits.mapIt(it.σ_b),
                  "expLimits" : expLimits.mapIt(it.limit)})
  ggplot(df, aes("σ_s", "σ_b", color = "expLimits")) +
    geom_point() +
    geom_text(aes = aes(text = "expLimits",
                        y = f{`σ_b` + 0.01})) +
    xMargin(0.05) + yMargin(0.05) +
    ggtitle(&"Expected limit after {nmc} MC toys for different σ_s, σ_b") +
    ggsave(SanityPath / "expected_limits_σ_s_σ_b.pdf")

proc sanityCheckRealSystematics(ctx: Context, log: Logger) =
  ## Generates examples histograms for the case of using real systematics. Maybe also
  ## compute a limit for two cases using the regular procedures for this (including plots
  ## in that case).
  let syst = initSystematics(
    σ_sig = 0.04692492913207222, # from sqrt(squared sum) of signal uncertainties
    σ_back = 0.002821014576353691,#, # from sqrt(square sum) of back uncertainties
    σ_p = 0.05 # from sqrt(squared sum of x / 7) position uncertainties
  )
  ctx.systematics = syst


proc sanity(
  scanSigmaLimits = false, # can be disabled, as it's time consuming
  backgroundInterp = false, # can be disabled, as it's time consuming
  limitKind = lkMCMC, # for the sigma limits sanity check
  radius = 40.0, σ = 40.0 / 3.0, energyRange = 0.6.keV, nxy = 10, nE = 20,
  rombergIntegrationDepth = 5,
  nmcSigmaLimits = 500
     ) =
  ##
  ## TODO:
  ## How do I make sure to use the exact same parameters as for the main code? Instead of copying here
  ## maybe define a dirty template that "defines" the parameters?
  let path = "/home/basti/CastData/ExternCode/TimepixAnalysis/resources/LikelihoodFiles/"
  let backFiles = @[(2017, "lhood_2017_all_chip_septem_dbscan.h5"),
                    (2018, "lhood_2018_all_chip_septem_dbscan.h5")]
  #let path = "/tmp/"
  #let backFiles = @["lhood_2017_all_vetoes_dbscan_cdl_mapping_fixed.h5",
  #                  "lhood_2018_all_vetoes_dbscan_cdl_mapping_fixed.h5"]

  let backgroundTime = 3318.Hour ## TODO: FIX ME GET FROM FILES
  let trackingTime = 169.Hour ## TODO: FIX ME GET FROM FILES

  var log = newFileLogger("sanity.log", fmtStr = "[$date - $time] - $levelname: ")
  log.infos("Input"):
    &"Input path: {path}"
    &"Input files: {backFiles}"

  log.infos("Time"):
    &"Total background time: {backgroundTime}"
    &"Total tracking time: {trackingTime}"
    &"Ratio of tracking to background time: {trackingTime / backgroundTime}"

  let useConstantBackground = false
  var ctx = initContext(
    path, backFiles, useConstantBackground = useConstantBackground,
    radius = radius, sigma = σ, energyRange = energyRange,
    backgroundTime = backgroundTime, trackingTime = trackingTime,
    nxy = nxy, nE = nE,
    σ_sig = 0.04692492913207222, # from sqrt(squared sum) of signal uncertainties
    σ_back = 0.002821014576353691,#, # from sqrt(square sum) of back uncertainties
    σ_p = 0.05,
    rombergIntegrationDepth = rombergIntegrationDepth
  ) # from sqrt(squared sum of x / 7) position uncertainties

  # 1. detection efficiency checks
  ctx.sanityCheckDetectionEff(log)

  # 1. background related checks
  ctx.sanityCheckBackground(log)

  # 2. raytracing
  ctx.sanityCheckRaytracingImage(log)

  # 3. background interpolation
  if backgroundInterp:
    ctx.sanityCheckBackgroundInterpolation(log)

  # 4. background sampling
  ctx.sanityCheckBackgroundSampling(log)

  # 5. signal
  ctx.sanityCheckSignal(log)

  # 6. likelihood, including signal vs. background
  # reset systematics to "off" (certain)
  ctx.systematics = initSystematics()
  # to compute likelihood things without any systematics
  ctx.sanityCheckLikelihoodNoSystematics(log)

  # 7. compute likelihood behavior when applying systematics
  ctx.sanityCheckLikelihoodSyst(log)

  # 8.
  if scanSigmaLimits:
    ctx.sanityCheckSigmaLimits(log, limitKind, nmcSigmaLimits)

  # 9. sanity checks for length of MCMC & starting parameters & allowed steps?
  # ?
  # random starting parameters in each case, but fixed for comparison of different chain lengths
  # i.e. we can just cut off the chain at N and use only first N, M, O, ... thousand entries and compare
  # the "finesse" of the result
  # - different chain length
  # - different burn in lengths ?
  # - different number of chains ?
  # Note: let's compute the real systematics case first so we know how slow the "real integral" approach
  # actually is. Then we know whether it makes sense to use the real systematics for this study or not.

  # 10. compute likelihood examples for realistic systematics. Comparison to numerical integration
  # will either be rather imprecise or take a long while.. Hm.
  ## XXX: note this will be used only for *calls to real procedures*. the general systematics
  ## are also handled in `saniyCheckLikelihoodSyst`
  #ctx.sanityCheckRealSystematics(log)

  # 11. anything else?

proc limit(
    files: seq[string] = @[],
    years: seq[int] = @[],
    path = "/home/basti/CastData/ExternCode/TimepixAnalysis/resources/LikelihoodFiles/",
    useConstantBackground = false,
    radius = 40.0, σ = 40.0 / 3.0, energyRange = 0.6.keV, nxy = 10, nE = 20,
    σ_sig = 0.04692492913207222,
    σ_back = 0.002821014576353691,
    σ_p = 0.05,
    limitKind = lkBayesScan,
    computeLimit = false,
    scanSigmaLimits = false,
    nmc = 1000,
    plotFile = "", # if given, will plot this file instead of doing limits
    bins = 50, # number of bins to use for plot
    xLow = 0.0, xHigh = 0.0,
    yLow = 0.0, yHigh = 0.0,
    xLabel = "Limit", yLabel = "Count",
    linesTo = 1000,
    outpath = "/tmp/",
    suffix = ""
     ): int =
  ## dummy return an `int`, otherwise run into some cligen bug
  let backgroundTime = 3318.Hour ## TODO: FIX ME GET FROM FILES
  let trackingTime = 169.Hour ## TODO: FIX ME GET FROM FILES

  let files = if files.len == 0:
                @[(2017, "lhood_2017_all_chip_septem_dbscan.h5"),
                  (2018, "lhood_2018_all_chip_septem_dbscan.h5")]
              else:
                doAssert files.len == years.len, "Every file must be given an associated year!"
                var f = newSeq[(int, string)]()
                for i in 0 ..< files.len:
                  f.add (years[i], files[i])
                f
  var ctx = initContext(
    path, files, useConstantBackground = useConstantBackground,
    radius = radius, sigma = σ, energyRange = energyRange,
    backgroundTime = backgroundTime, trackingTime = trackingTime,
    nxy = nxy, nE = nE,
    σ_sig = σ_sig, # from sqrt(squared sum) of signal uncertainties
    σ_back = σ_back,#, # from sqrt(square sum) of back uncertainties
    σ_p = σ_p) # from sqrt(squared sum of x / 7) position uncertainties
    # large values of σ_sig cause NaN and grind some integrations to a halt!
    ## XXX: σ_sig = 0.3)
  #echo ctx.interp.expCounts
  #if true: quit()

  var rnd = wrap(initMersenneTwister(299792458 + 2))
  # writeFile(&"/tmp/reference_candidates_{count}_s_{ctx.σsb_sig}_b_{ctx.σsb_back}.bin", cands.toFlatty())
  #let cands = newSeq[Candidate]() #fromFlatty(readFile("/tmp/reference_candidates_1001_s_0.3_b_0.05.bin"), seq[Candidate]) # drawCandidates(ctx, rnd, toPlot = true)
  #echo cands
  #plotCandidates(cands)

  #echo ctx.computeLimit(cands, lkBayesScan)
  #if true: quit()
  let cands = drawCandidates(ctx, rnd, toPlot = true)
  plotCandidates(cands)
  ctx.g_ae² = 1e-10 * 1e-10 #limit
  #echo ctx.computeLimit(cands, lkBayesScan)
  if computeLimit:
    echo ctx.monteCarloLimits(rnd, limitKind, nmc = nmc)
    return
  #echo ctx.monteCarloLimits(rnd, lkMCMC)
  #if true: quit()

  if plotFile.len > 0:
    echo "NOTE: Make sure the input parameters match the parameters used to generate the file ", plotFile
    let df = readCsv(plotFile)
    let limitNoSignal = ctx.computeLimit(rnd, newSeq[Candidate](), limitKind)
    ctx.plotMCLimitHistogram(df["limits", float].toSeq1D,
                             df["candsInSens", int].toSeq1D,
                             limitKind, nmc,
                             limitNoSignal,
                             bins = bins,
                             xlimit = (xLow, xHigh),
                             ylimit = (yLow, yHigh),
                             xLabel = xLabel, yLabel = yLabel,
                             linesTo = linesTo)

    return

  if true:
    let limits = ctx.computeParallelLimits(limitKind, nmc)
    let limitNoSignal = ctx.computeLimit(rnd, newSeq[Candidate](), limitKind)
    ctx.plotMCLimitHistogram(limits.mapIt(it[0]), limits.mapIt(it[1]),
                             limitKind, nmc,
                             limitNoSignal = limitNoSignal,
                             outpath = outpath,
                             suffix = suffix)

when isMainModule:
  import cligen/argcvt
  proc argParse(dst: var keV, dfl: keV,
                a: var ArgcvtParams): bool =
    try:
      let aStr = a.val
      if aStr.endsWith("keV"):
        proc removeSuffix(s, p: string): string =
          result = s
          result.removeSuffix(p)
        dst = aStr.removeSuffix("keV").strip.parseFloat.keV
      else:
        dst = aStr.strip.parseFloat.keV
      result = true
    except:
      result = false

  proc argHelp*(dfl: keV; a: var ArgcvtParams): seq[string] =
    result = @[ a.argKeys, "keV", $dfl ]

  # multi dispatch is broken atm
  dispatchMulti([limit], [sanity])
  when false:
    block:
      block SandB:

        let candidates = cands
        template helper(): untyped {.dirty.} =
          ctx.g_ae² = 1e-13 * 1e-13 ## to have reference values to quickly rescale!
          let s_tot = expRate(ctx)
          var σ_s: float
          var σ_b: float
          case ctx.uncertainty
          of ukUncertainSig:
            σ_s = ctx.σs_sig
          of ukUncertainBack:
            σ_b = ctx.σb_back
          of ukUncertain:
            σ_s = ctx.σsb_sig
            σ_b = ctx.σsb_back
          else: discard
          var cands = newSeq[(float, float)](candidates.len)
          for i, c in candidates:
            cands[i] = (ctx.expectedSignal(c.energy, c.pos).float,
                        ctx.background(c.energy, c.pos).float)

        helper()
        when false: # only B
          proc fn(x: seq[float]): float =
            ctx.g_ae² = x[0]
            if x[1] < -0.8: return 0.0

            let s_totg = s_tot.rescale(ctx.g_ae²)
            echo "rescaled ", s_tot, " to ", s_totg
            L(s_totg,
              s_i.rescale(ctx.g_ae²),
              b_i * (1 + x[1]),
              0.0, 0.0,
              x[1], σ_b)

          let (chain, acceptanceRate) = rnd.build_MH_chain(@[0.1e-21, 0.2], @[1e-21, 0.4], 100_000, fn)
          echo "Acceptance rate: ", acceptanceRate
          echo "Last ten states of chain: ", chain[^10 .. ^1]
          plotChain(chain)

        when false: # S and B
          proc fn(x: seq[float]): float =
            ctx.g_ae² = x[0]
            if x[1] < -0.8: return 0.0

            let s_totg = s_tot.rescale(ctx.g_ae²)
            L(s_totg,
              s_i.rescale(ctx.g_ae²) * (1 + x[2]),
              b_i * (1 + x[1]),
              x[2], σ_s,
              x[1], σ_b)

          let (chain, acceptanceRate) = rnd.build_MH_chain(@[0.1e-21, 0.2, -0.1], @[1e-21, 0.4, 0.4], 100_000, fn)
          echo "Acceptance rate: ", acceptanceRate
          echo "Last ten states of chain: ", chain[^10 .. ^1]
          plotChain(chain)





      block XandY:
        when false:
          let candidates = cands
          template helper(): untyped {.dirty.} =
            ctx.g_ae² = 1e-13 * 1e-13 ## to have reference values to quickly rescale!

            var cands = newSeq[(float, float)](candidates.len)
            let SQRT2 = sqrt(2.0)
            let σ_p = ctx.σ_p
            let s_tot = expRate(ctx)
            for i, c in candidates:
              let sig = ctx.detectionEff(c.energy) * ctx.axionFlux(c.energy) * conversionProbability()
              cands[i] = (sig.float,
                          ctx.background(c.energy, c.pos).float)

          helper()
          proc fn(x: seq[float]): float =
            ctx.g_ae² = x[0]
            if x[0] < 0.0: return 0.0
            let s_totg = s_tot.rescale(ctx.g_ae²)
            #echo "rescaled ", s_tot, " to ", s_totg
            let θ_x = x[1]
            let θ_y = x[2]
            ctx.θ_x = θ_x
            ctx.θ_y = θ_y
            let P1 = exp(-s_totg)
            let P2 = exp(-pow(θ_x / (SQRT2 * σ_p), 2)) * exp(-pow(θ_y / (SQRT2 * σ_p), 2))
            var P3 = 1.0
            for i in 0 ..< cands.len:
              let (s_init, b_c) = cands[i]
              if b_c.float != 0.0:
                let s_c = (s_init.rescale(ctx.g_ae²) * ctx.raytracing(candidates[i].pos)).float
                P3 *= (1 + s_c / b_c)
            result = P1 * P2 * P3

          let (chain, acceptanceRate) = rnd.build_MH_chain(@[0.1e-21, 0.3, -0.3], @[1e-21, 0.4, 0.4], 500_000, fn)
          echo "Acceptance rate: ", acceptanceRate
          echo "Last ten states of chain: ", chain[^10 .. ^1]
          plotChain(chain)

      block All:
        when true:
          echo ctx.computeMCMCLimit(cands)

          echo ctx.monteCarloLimits(rnd, lkMCMC)