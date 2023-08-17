template plotHandler(body: untyped): untyped {.dirty.} =
  (proc(h5f: H5FileObj, fileInfo: FileInfo, pd: PlotDescriptor, config: Config): (string, PlotV) =
     body)

proc moreCustom(fileInfo: FileInfo, config: Config): seq[PlotDescriptor] =
  let selector = initSelector(config)
  block ToA:
    let customPlot = CustomPlot(kind: cpHistogram, x: "ToA")
    var pd = PlotDescriptor(runType: fileInfo.runType,
                              name: "ToA",
                              xLabel: "ToA",
                              yLabel: "Count",
                              title: "ToA histogramming",
                              selector: selector,
                              isCenterChip: true,
                              chip: -1, ## will be set to center chip when reading data!
                              runs: fileInfo.runs,
                              plotKind: pkCustomPlot,
                              customPlot: customPlot)
    pd.processData = plotHandler:
      var allData = newSeq[int32]()
      echo "Reading all TOA"
      for r in pd.runs:
        echo "Reading toa of run ", r
        let toas = h5f.readVlen(fileInfo, r, "ToA", pd.selector, fileInfo.centerChip, dtype = uint16)
        # shift all ToA values to start at 0 in each cluster
        for toa in toas:
          let toaInt = toa.mapIt(it.int32)
          let minToa = toaInt.min()
          allData.add toaInt.mapIt(it - minToa)
      result[0] = buildOutfile(pd, fileDir, fileType)
      let title = buildTitle(pd)
      echo "Plotting hist now"
      result[1] = plotHist(allData, title, pd.name, result[0], binS = 1.0,
                           binR = (-0.5, 100.0))
    result.add pd
  block PixelBarChart:

    template barChart(nam, tit, body: untyped): untyped {.dirty.} =
      let customPlot = CustomPlot(kind: cpHistogram, x: "ToA")
      var pd = PlotDescriptor(runType: fileInfo.runType,
                              name: nam,
                              xLabel: "Pixel",
                              yLabel: "Count",
                              title: tit,
                              selector: selector,
                              isCenterChip: true,
                              chip: 0,
                              runs: fileInfo.runs,
                              plotKind: pkCustomPlot,
                              customPlot: customPlot)
      pd.processData = plotHandler:
        echo "Reading all data for pixel bar chart"
        var
          x = newSeqOfCap[uint8](1_000_000)
          y = newSeqOfCap[uint8](1_000_000)
          ch = newSeqOfCap[uint16](1_000_000)
        for r in pd.runs:
          echo "Reading pixels of run ", r
          x.add h5f.readVlen(fileInfo, r, "x", selector, chipNumber = pd.chip, dtype = uint8).flatten
          y.add h5f.readVlen(fileInfo, r, "y", selector, chipNumber = pd.chip, dtype = uint8).flatten
          ch.add h5f.readVlen(fileInfo, r, "ToT", selector, chipNumber = pd.chip, dtype = uint16).flatten

        let dfP = toDf({"x" : x.mapIt(it.int), "y" : y.mapIt(it.int), "ch" : ch.mapIt(it.int)})
        let outpath = fileDir ## Global in `plotData.nim`
        ggplot(dfP, aes("x", "y", color = "ch")) +
          geom_point() +
          ggsave(&"{outpath}/pixels_after_background_rate.pdf")
        # now build set of pixels
        var pixTab = initCountTable[(uint8, uint8)]()
        var pixTotTab = initCountTable[string]() # string to later read easier
        for i in 0 ..< x.len:
          pixTab.inc (x[i], y[i])
          pixTotTab.inc $(x[i], y[i]), ch[i].int
        # produce bars & counts
        var pixels = newSeqOfCap[string](pixTab.len)
        var counts = newSeqOfCap[int](pixTab.len)
        var countsToT = newSeqOfCap[int](pixTab.len)
        for k, v in pixTab:
          pixels.add $k
          counts.add v
        for i in 0 ..< pixels.len:
          countsTot.add pixTotTab[pixels[i]]
        var df = toDf(pixels, counts, countsTot)
          .arrange("countsTot", SortOrder.Descending)
        let totalCount = df.len
        df.writeCsv("pixel_occurence.csv")
        echo df
        df = df.filter(f{int -> bool: `counts` > 9})
        result[0] = buildOutfile(pd, fileDir, fileType)
        let title = pd.title & ", # active pixel: " & $totalCount
        var plt = initPlotV(title, pd.xlabel, "#", width = 1600, height = 1200)
        body
        result[1] = plt
      result.add pd
    block:
      barChart("pix_bar_chart", "Bar chart of occurences of pixels"):
        plt.pltGg = ggplot(df, aes("pixels", "counts")) +
            geom_bar(stat = "identity") +
            scale_y_continuous() +
            xlab("Pixels", rotate = -45, alignTo = "right") +
            plt.theme # just add the theme directly
    block:
      barChart("pix_tot_bar_chart", "Bar chart of occurences of pixels with ToT taken into account"):
        plt.pltGg = ggplot(df, aes("pixels", "countsTot")) +
            geom_bar(stat = "identity") +
            scale_y_continuous() +
            xlab("Pixels", rotate = -45, alignTo = "right") +
            plt.theme # just add the theme directly
