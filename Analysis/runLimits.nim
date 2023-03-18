import os, strutils, sugar, strformat, times
import shell

var CurrentFile: string

proc ctrlc() {.noconv.} =
  echo "\nInterrupted while running processing of file: ", CurrentFile
  echo "Check the `processed.txt` file in the output path to see which files were processed successfully!"
  quit()

proc main(path = "/t/lhood_outputs_adaptive_fadc/",
          outpath = "/t/lhood_outputs_adaptive_fadc_limits/",
          prefix = "likelihood_cdl2018_Run2_crAll",
          nmc = 2000) =
  setControlCHook(ctrlc)
  let t0 = epochTime()
  let alreadyProcessed = readFile(outpath / "processed.txt").splitLines
  var processed = open(outpath / "processed.txt", fmAppend)
  echo "Limit calculation will be performed for the following files:"
  for file in walkFiles(path / prefix & "*.h5"):
    if file notin alreadyProcessed:
      echo file
  for file in walkFiles(path / prefix & "*.h5"):
    CurrentFile = file
    if CurrentFile in alreadyProcessed:
      echo "Skipping file ", CurrentFile, " as it was already processed."
    let t1 = epochTime()
    let fRun2 = file
    # construct Run3 file
    let fRun3 = file.replace("_Run2_", "_Run3_")
    # construct suffix
    let suffixArg = file.extractFilename.dup(removePrefix(prefix)).dup(removeSuffix(".h5"))
    let suffix = "--suffix=" & suffixArg
    let path = "--path \"\""
    # construct command
    let (res, err) = shellVerbose:
      mcmc_limit_calculation limit -f ($fRun2) -f ($fRun3) --years 2017 --years 2018 --σ_p 0.05 --limitKind lkMCMC --nmc ($nmc) ($suffix) ($path) --outpath ($outpath)
    # write output to a log file
    let logfile = outpath / "mcmc_limit_output_" & suffixArg & ".log"
    writeFile(logfile, res)
    # only continue if no error
    if err != 0:
      echo "ERROR: The previous command (see log file: ", logfile, ") did not finish successfully. Aborting."
      quit()

    processed.write(CurrentFile & "\n")
    echo "Computing single limit took ", epochTime() - t1, " s"

  echo "Computing all limits took ", epochTime() - t0, " s"
  processed.close()

when isMainModule:
  import cligen
  dispatch main
