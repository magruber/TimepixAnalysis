import json
import plotly
import strutils, strformat, tables, sugar, sequtils
import chroma
import jsffi except `&`
import jsbind
#import json
from dom import getElementById
import jswebsockets# except Event
include karax / prelude
import karax / [kdom, vstyles]

import components / [button, plotWindow, figSelect, utils]

let plt = newPlotly()

const data = staticRead("/home/basti/CastData/ExternCode/TimepixAnalysis/Plotting/karaPlot/calibration_cfNoFadc_cfNoPolya.json")

#type
#  Dropdown = object

# for dynamic client:
# add fields for
# - bins  <- to change binning of an existing plot. Entering that will request
#   the same plot with the desired binning
# - ...

# add event option to show events / clusters (field for event number)
# incuding centerX, centerY

var i = 0

proc main =

  echo "Start parsing..."
  let jData = parseJsonToJs(data) #parseJson(data)

  for k in keys(jData):
    echo "k is ", k

  echo toString(jData)
  echo "...parsed"
  let svgPairs = jData["svg"] #.getFields
  let pltPairs = jData["plotly"] #.getFields
  let svgKeys = toSeq(keys(svgPairs))
  let pltKeys = toSeq(keys(pltPairs))
  let allKeys = concat(svgKeys, pltKeys)
  let nSvg = svgKeys.len
  let nPlots = svgKeys.len + pltKeys.len
  for k in keys(svgPairs):
     echo k

  for k in keys(pltPairs):
     echo k
  var i = 0
  #plt.plot("plot0", pltPairs[pltKeys[0]]["Traces"],
  #         pltPairs[pltKeys[0]]["Layout"])

  template getNext(idx: int): kstring =
    if idx + 1 < allKeys.len:
      kstring(allKeys[idx + 1])
    else:
      kstring""

  template getPrev(idx: int): kstring =
    if idx > 0:
      kstring(allKeys[idx - 1])
    else:
      kstring""

  func decInRange(idx: var int) {.inline.} =
    if idx > 1:
      dec idx
    else:
      idx = 0

  func incInRange(idx: var int) {.inline.} =
    if idx < allKeys.high:
      inc idx
    else:
      idx = allKeys.high

  proc renderPlotly() =
    # make a plotly plot
    if i >= nSvg:
      let dd = pltPairs[pltKeys[i - nSvg]]
      plt.newPlot("plotly", dd["Traces"], dd["Layout"])
      let plotlyPlot = kdom.document.getElementById("plotly")
      plotlyPlot.style.visibility = "visible"

    else:
      # hide plot
      let plotlyPlot = kdom.document.getElementById("plotly")
      plotlyPlot.style.visibility = "hidden"


  #echo pltPairs[pltKeys[0]]
  proc render(): VNode =

    #var svgPplt = fnamesSvg[0]
    #for x in jData["svg"]:
    result = buildHtml(tdiv):
      h1(text "Static karaPlot")
      p:
        renderButton("Previous",
                     onClickProc = () => decInRange i)
        renderButton("Next",
                     onClickProc = () => incInRange i)
        br()
        text "Next: " & $i & " " & getNext(i)
        br()
        text "Previous: " & $i & " " & getPrev(i)
      p:
        tdiv(class = "dropdown")
        renderButton("Dropdown",
                     class = "dropbtn",
                     onClickProc = () => kdom.document.getElementById("myDropdown").classList.toggle("show"))
        tdiv(id = "myDropdown",
             class = "dropdown-content"):
          var idx = 0
          for k in keys(svgPairs):
            echo "K is ", k, " idx " , idx
            p:
              renderFigSelect($k,
                              idx,
                              onClickProc = (event: kdom.Event, node: VNode) => (i = node.id.parseInt))
            inc idx
          for k in keys(pltPairs):
            echo "K is ", k, " idx " , idx
            p:
              renderFigSelect($k,
                              idx,
                              onClickProc = (event: kdom.Event, node: VNode) => (i = node.id.parseInt))
            inc idx
      p:
        span(text $svgKeys)
        span(text $i)
      p:
        if i < nSvg:
          renderSvgPlot(svgPairs[svgKeys[i]])
        # create `div` for the plotly Plot
        tdiv(id = "plotly",
             class = "plot-style")
        #style = style(StyleAttr.width, kstring"60%"))
        #else:
        #  iframe:
        #    #let el = kdom.document.getElementById("plot0")
        #    let dd = pltPairs[pltKeys[i - nSvg]]
        #    # echo el.repr
        #    # verbatim("<div id='plot0'></div>")
        #      #tdiv(id = "plot0")
        #      #react(plt, "plot0",
        #      #      dd["Traces"], dd["Layout"], output_type = "div")
        #      renderPlotly(plt, pltPairs[pltKeys[i - nSvg]])

  setRenderer render, "ROOT", renderPlotly
  setForeignNodeId "plotly"

when isMainModule:
  main()
