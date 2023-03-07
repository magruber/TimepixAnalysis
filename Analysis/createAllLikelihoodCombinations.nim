import shell, sequtils, strformat, strutils, os
from std / times import epochTime
from ingrid / ingrid_types import ChipRegion

import cligen / [procpool, mslice, osUt]

#[
Computes all combinations of the following cases
- for year in years of data files given:
  - for region in chip region:
    - no vetoes
    - +scinti veto
    - +FADC veto
    - +septem veto
    - +line veto
All veto combinations are treated additive, with the priority being the one
defined by the local `FlagKind`, but only including the ones you specify!
For that reason it is not possible to in one go generate all *individual* veto
cases at the same time as computing the combined vetoes. Maybe this will be added
in the future.

It will also write the output written by the program to the same output directory
with the same name, but a `.log` extension.
]#

##: XXX: ADD THE `--tracking` FLAG IF DESIRED

type
  ## A simplified reproduction of the `likelihood` `FlagKind` type only containing the
  ## aspects we care about with an additional `fkNoVeto`
  FlagKind = enum
    fkNoVeto   # = "",
    fkScinti   # = "--scintiveto"
    fkFadc     # = "--fadcveto"
    fkSeptem   # = "--septemveto"
    fkLineVeto # = "--lineveto"
    fkExclusiveLineVeto # line veto *without* septem veto & lvRegular, ecc cut 1.0
                        # important this is last!

  Combination = object
    fname: string
    calib: string
    year: int
    region: ChipRegion
    vetoes: set[FlagKind]
    vetoPercentile: float # FADC veto percentile

proc toStr(fk: FlagKind): string =
  case fk
  of fkNoVeto:   ""
  of fkScinti:   "--scintiveto"
  of fkFadc:     "--fadcveto"
  of fkSeptem:   "--septemveto"
  of fkLineVeto: "--lineveto"
  of fkExclusiveLineVeto: "--lineveto"

proc genVetoStr(vetoes: set[FlagKind]): string =
  for v in vetoes:
    result = result & " " & (v.toStr())

iterator genCombinations(f2017, f2018: string,
                         c2017, c2018: string,
                         regions: set[ChipRegion],
                         vetoes: set[FlagKind],
                         fadcVetoPercentiles: seq[float]
                        ): Combination =
  for tup in zip(@[f2017, f2018].filterIt(it.len > 0), @[c2017, c2018]):
    let (fname, calib) = (tup[0], tup[1])
    let year = if fname == f2017: 2017 else: 2018
    for region in regions:
      var vetoSet: set[FlagKind]
      for veto in FlagKind: # iterate over `FlagKind` checking if this veto contained in input
        if veto in vetoes:  # guarantees we return in order of `FlagKind`. Each *additional*
          vetoSet.incl veto # combination is therefore returned
          if veto == fkExclusiveLineVeto:
            # remove septem veto
            vetoSet.excl fkSeptem
            vetoSet.excl fkLineVeto # don't need line veto anymore
        var comb = Combination(fname: fname, calib: calib, year: year,
                               region: region, vetoes: vetoSet,
                               vetoPercentile: -1.0)
        if fkFadc in vetoSet: # if FADC contained, yield all percentiles after another
          for perc in fadcVetoPercentiles:
            comb.vetoPercentile = perc
            yield comb
        else:
          yield comb

proc buildFilename(comb: Combination, outpath: string): string =
  let runPeriod = if comb.year == 2017: "Run2" else: "Run3"
  result = &"{outpath}/likelihood_cdl2018_{runPeriod}_{comb.region}"
  for v in comb.vetoes:
    let vetoStr = (v.toStr).replace("--", "").replace("veto", "")
    if vetoStr.len > 0: # avoid double `_`
      result = result & "_" & vetoStr
  if comb.vetoPercentile >= 0.0:
    result = result & "_vetoPercentile_" & $comb.vetoPercentile
  result = result & ".h5"

proc runCommand(comb: Combination, cdlFile, outpath: string,
                cdlYear: int, dryRun: bool, readOnly: bool) =
  let vetoStr = genVetoStr(comb.vetoes)
  let outfile = buildFilename(comb, outpath)
  let regionStr = &"--region={comb.region}"
  let cdlYear = &"--cdlYear={cdlYear}"
  let cdlFile = &"--cdlFile={cdlFile}"
  let calibFile = if fkFadc in comb.vetoes: &"--calibFile={comb.calib}"
                  else: ""
  let vetoPerc = if comb.vetoPercentile > 0.0: &"--vetoPercentile={comb.vetoPercentile}" else: ""
  let readOnly = if readOnly: "--readOnly" else: ""
  let fname = comb.fname
  if not dryRun:
    let (res, err) = shellVerbose:
      "likelihood -f" ($fname) "--h5out" ($outfile) ($regionStr) ($cdlYear) ($vetoStr) ($cdlFile) ($readOnly) ($calibFile) ($vetoPerc)
    # first write log file
    let logOutput = outfile.extractFilename.replace(".h5", ".log")
    writeFile(&"{outpath}/{logOutput}", res)
    # then check error code. That way  we have the log at least!
    doAssert err == 0, "The last command returned error code: " & $err
  else:
    shellEcho:
      "likelihood -f" ($fname) "--h5out" ($outfile) ($regionStr) ($cdlYear) ($vetoStr) ($cdlFile) ($readOnly) ($calibFile) ($vetoPerc)

type
  InputData = object
    fname: array[512, char] # fixed array for the data filename
    calib: array[512, char] # fixed array for filename of calibration file
    year: int
    region: ChipRegion
    vetoes: set[FlagKind]
    vetoPercentile: float

proc toArray(s: string): array[512, char] = # could mem copy, but well
  doAssert s.len < 512
  for i in 0 ..< s.len:
    result[i] = s[i]

proc fromArray(ar: array[512, char]): string =
  result = newStringOfCap(512)
  for i in 0 ..< 512:
    if ar[i] == '\0': break
    result.add ar[i]

proc `$`(id: InputData): string =
  $(fname: id.fname.fromArray(), calib: id.calib.fromArray(),
    year: id.year, region: id.region, vetoes: id.vetoes,
    vetoPercentile: id.vetoPercentile)

proc toInputData(comb: Combination): InputData =
  result = InputData(fname: comb.fname.toArray(), calib: comb.calib.toArray(),
                     year: comb.year, region: comb.region, vetoes: comb.vetoes,
                     vetoPercentile: comb.vetoPercentile)

proc toCombination(data: InputData): Combination =
  result = Combination(fname: data.fname.fromArray(), calib: data.calib.fromArray(),
                       year: data.year, region: data.region, vetoes: data.vetoes,
                       vetoPercentile: data.vetoPercentile)

proc main(f2017, f2018: string = "", # paths to the Run-2 and Run-3 data files
          c2017, c2018: string = "", # paths to the Run-2 and Run-3 calibration files (needed for FADC veto)
          regions: set[ChipRegion], # which chip regions to compute data for
          vetoes: set[FlagKind],
          cdlFile: string,
          outpath = "out",
          cdlYear = 2018,
          dryRun = false,
          multiprocessing = false,
          fadcVetoPercentiles: seq[float] = @[]) =
  if fkFadc in vetoes and ( # stop if FADC veto used but calibration file missing
     (f2017.len > 0 and c2017.len == 0) or
     (f2018.len > 0 and c2018.len == 0)):
    doAssert false, "When using the FADC veto the corresponding calibration file to the background " &
      "data file is required."
  if not multiprocessing: # run all commands in serial
    for comb in genCombinations(f2017, f2018, c2017, c2018, regions, vetoes, fadcVetoPercentiles):
      runCommand(comb, cdlFile, outpath, cdlYear, dryRun, readOnly = false)
  else:
    var cmds = newSeq[InputData]()
    for comb in genCombinations(f2017, f2018, c2017, c2018, regions, vetoes, fadcVetoPercentiles):
      cmds.add comb.toInputData()

    for cmd in cmds:
      echo "Command: ", cmd
      echo "As filename: ", buildFilename(cmd.toCombination(), outpath)
    if not dryRun:
      # run them using a procpool
      let t0 = epochTime()
      let jobs = 8 # running with 28 jobs _definitely_ runs out of RAM on a machine with 64GB. 10 seems to work fine.
                    # However, most of the jobs are done very quickly anyway. The crAll (esp incl septem/line veto)
                    # are by far the slowest. So while 10 is slower than 28, the difference is small.
      ## See note at the bottom of the file.
      # We use a cligen procpool to handle running all jobs in parallel
      var pp = initProcPool((
        proc(r, w: cint) =
          let i = open(r)
          var o = open(w, fmWrite)
          var cmd: InputData
          while i.uRd(cmd):
            echo "Running value: ", cmd
            runCommand(cmd.toCombination(), cdlFile, outpath, cdlYear, dryRun, readOnly = true)
            discard w.wrLine "INFO: Finished input pair: " & $cmd
      ), framesLines, jobs)

      proc prn(m: MSlice) = echo m
      pp.evalOb cmds, prn
      echo "Running all likelihood combinations took ", epochTime() - t0, " s"

when isMainModule:
  import cligen
  dispatch main
