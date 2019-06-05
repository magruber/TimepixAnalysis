import parsecsv, os, streams, strutils, strformat, nimhdf5, tables, sequtils, macros
import seqmath, algorithm
import plotly, mpfit, nlopt, nimpy
import ingrid / [ingrid_types, tos_helpers, calibration]
import docopt
import helpers / utils
import chroma
import nimsvg, ospaths, random, xmlparser, xmltree


const docStr = """
Usage:
  cdl_spectrum_creation <h5file> [options]
  cdl_spectrum_creation -h | --help
  cdl_spectrum_creation --version

Options:
  -h, --help   Show this help
  --version    Show the version number
"""
const doc = withDocopt(docStr)

## some different color definitions
const Color1 = color(1.0, 0.0, 102.0 / 256.0)
const Color2 = color(0.0, 153.0 / 256.0, 204 / 256.0)
const black = color(0.0, 0.0, 0.0)
const ColorTGelb = parseHex("FFC107")
const ColorTBlau = parseHex("0288D1")
const ColorTDBlau = parseHex("0288D1")
const ColorTBGrau = parseHex("BDBDBD")
const ColorTGrau = parseHex("757575")
const ColorTHGrau = color(0.92, 0.92, 0.92)


type
  TargetKind = enum
    tEmpty = ""
    tCu = "Cu"
    tMn = "Mn"
    tTi = "Ti"
    tAg = "Ag"
    tAl = "Al"
    tC = "C"

  FilterKind = enum
    fEmpty = ""
    fEpic = "EPIC"
    fCr = "Cr"
    fNi = "Ni"
    fAg = "Ag"
    fAl = "Al"
    fTi = "Ti"

  TargetFilterKind = enum
    tfCuNi15 = "Cu-Ni-15kV"
    tfMnCr12 = "Mn-Cr-12kV"
    tfTiTi9 = "Ti-Ti-9kV"
    tfAgAg6 = "Ag-Ag-6kV"
    tfAlAl4 = "Al-Al-4kV"
    tfCuEpic2 = "Cu-EPIC-2kV"
    tfCuEpic0_9 = "Cu-EPIC-0.9kV"
    tfCEpic0_6 =  "C-EPIC-0.6kV"

  CdlRun = object
    number: int
    runType: RunTypeKind
    hasFadc: bool
    target: TargetKind
    filter: FilterKind
    hv: float

  CdlFitFunc = proc(p_ar: seq[float], x: float): float

  #CdlFit = object
  #  target: TargetKind
  #  filter: FilterKind
  #  hv: float
  #  fit: CdlFitFunc

  FitFuncKind = enum
    ffConst, ffPol1, ffPol2, ffGauss, ffExpGauss

  FitFuncArgs = object
    name: string
    case kind: FitFuncKind
    of ffConst:
      c: float
    of ffPol1:
      cp: float
    of ffPol2:
      cpp: float
    of ffGauss:
      gN: float
      gmu: float
      gs: float
    of ffExpGauss:
      ea: float
      eb: float
      eN: float
      emu: float
      es: float

  DataKind = enum
    Dhits = "hits"
    Dcharge = "charge"

const fixed = NaN


func getLines(hist, binning: seq[float], tfKind: TargetFilterKind): seq[FitFuncArgs] =
  ## this is a runtime generator for the correct fitting function prototype,
  ## i.e. it returns a seq of parts, which need to be combined to the complete
  ## function at runtime
  let muIdx = argmax(hist)
  case tfKind
  of tfCuNi15:
    ##the expGauss is not needed for the new data(2019)
    ##but maybe for the old data(2014)
    result.add FitFuncArgs(name: "Cu-Kalpha",
                           kind: ffGauss,
                           #ea: hist[muIdx], #/ 10.0, # * 1e-10,
                           #eb: hist[muIdx], #* 1e-2, # * 1e-12,
                           gN: hist[muIdx] / 10.0,
                           gmu: binning[muIdx],
                           gs: hist[muIdx] / 30.0)
    result.add FitFuncArgs(name: "Cu-esc",
                           kind: ffGauss,
                           #ea: hist[muIdx], #/ 80.0, # * 1e-10,
                           #eb: hist[muIdx], #* 1e-2, # * 1e-12,
                           gN: hist[muIdx] / 20.0,
                           gmu: binning[muIdx],
                           gs: hist[muIdx] / 15.0)
  of tfMnCr12:
    result.add FitFuncArgs(name: "Mn-Kalpha",
                           kind: ffExpGauss,
                           ea: hist[muIdx] * 1e-10,
                           eb: hist[muIdx] * 1e-12,
                           eN: hist[muIdx] / 2.0,
                           emu: 200.0, #binning[muIdx],
                           es: 13.0) #hist[muIdx] / 15.0)
    result.add FitFuncArgs(name: "Mn-esc",
                           kind: ffGauss,
                           #ea: hist[muIdx],
                           #eb: hist[muIdx],
                           gN: hist[muIdx] / 9.0,
                           gmu: 100.0, #binning[muIdx] / 2.0,
                           gs: 16.0) #hist[muIdx] / 30.0)
  of tfTiTi9:
    result.add FitFuncArgs(name: "Ti-Kalpha",
                           kind: ffGauss,
                           #ea: hist[muIdx] ,
                           #eb: hist[muIdx] ,
                           gN: hist[muIdx] / 10.0,
                           gmu: binning[muIdx] ,
                           gs: hist[muIdx] / 30.0)
    result.add FitFuncArgs(name: "Ti-esc-alpha",
                           kind: ffGauss,
                           gN: hist[muIdx] / 20.0,
                           gmu: binning[muIdx],
                           gs: hist[muIdx] / 15.0)
    result.add FitFuncArgs(name: "Ti-esc-beta",
                           kind: ffGauss,
                           gN: hist[muIdx] / 20.0,
                           gmu: binning[muIdx],
                           gs: hist[muIdx] / 15.0)
    result.add FitFuncArgs(name: "Ti-Kbeta",
                           kind: ffGauss,
                           gN: hist[muIdx] / 10.0,
                           gmu: binning[muIdx],
                           gs: hist[muIdx] / 15.0)
  of tfAgAg6:
    result.add FitFuncArgs(name: "Ag-Lalpha",
                          kind: ffGauss,
                          #ea: hist[muIdx] * 1e-10,
                          #eb: -hist[muIdx] * 1e-12,
                          gN: hist[muIdx] / 3.0,
                          gmu: binning[muIdx] * 2.0,
                          gs: hist[muIdx] / 30.0)
    result.add FitFuncArgs(name: "Ag-Lbeta",
                          kind: ffGauss,
                          gmu: binning[muIdx],
                          gN: hist[muIdx],
                          gs: hist[muIdx] / 10.0)
  of tfAlAl4:
    result.add FitFuncArgs(name: "Al-Kalpha",
                          kind: ffExpGauss,
                          ea: hist[muIdx] * 1e-10,
                          eb: hist[muIdx] * 1e-12,
                          eN: hist[muIdx] / 4.0,
                          emu: binning[muIdx],
                          es: hist[muIdx] / 10.0)
  of tfCuEpic2:
    result.add FitFuncArgs(name: "Cu-Lalpha",
                          kind: ffGauss,
                          gmu: binning[muIdx] / 4.0,
                          gN: hist[muIdx],
                          gs: hist[muIdx] / 10.0)
    result.add FitFuncArgs(name: "Cu-Lbeta",
                          kind: ffGauss,
                          #ea: hist[muIdx],# * 1e-10,
                          #eb: hist[muIdx],# * 1e-12,
                          gN: hist[muIdx] / 10.0,
                          gmu: binning[muIdx],
                          gs: hist[muIdx]  / 40.0)
  of tfCuEpic0_9:
    result.add FitFuncArgs(name: "O-Kalpha",
                          kind: ffGauss,
                          gmu: binning[muIdx] / 2.0,
                          gN: hist[muIdx],
                          gs: hist[muIdx] / 15.0)
    result.add FitFuncArgs(name: "C-Kalpha",
                          kind: ffGauss,
                          gmu: binning[muIdx] / 2.0,
                          gN: hist[muIdx],
                          gs: hist[muIdx] / 30.0)
    #result.add FitFuncArgs(name: "O-Lbeta",
    #                      kind: ffExpGauss,
    #                      ea: hist[muIdx]* 1e-10,
    #                      eb: hist[muIdx] * 1e-12,
    #                      eN: hist[muIdx],
    #                      emu: binning[muIdx],
    #                      es: hist[muIdx] / 20.0)
    #result.add FitFuncArgs(name: "Fe-Lalphabeta",
    #                      kind: ffGauss,
    #                      gmu: binning[muIdx],
    #                      gN: hist[muIdx],
    #                      gs: hist[muIdx] )
    #result.add FitFuncArgs(name: "Ni-Lalphabeta",
    #                      kind: ffGauss,
    #                      gmu: binning[muIdx],
    #                      gN: hist[muIdx],
    #                      gs: hist[muIdx] )
  of tfCEpic0_6:
    result.add FitFuncArgs(name: "C-Kalpha",
                           kind: ffGauss,
                           gN: hist[muIdx] / 4.0,
                           gmu: binning[muIdx] / 2.0,
                           gs: hist[muIdx] / 2.0)
    result.add FitFuncArgs(name: "O-Kalpha",
                           kind: ffGauss,
                           gN: hist[muIdx] / 4.0,
                           gmu: binning[muIdx],
                           gs: hist[muIdx]) #fixed)


func getLinesCharge(hist, binning: seq[float], tfKind: TargetFilterKind): seq[FitFuncArgs] =
  ## this is a runtime generator for the correct fitting function prototype,
  ## i.e. it returns a seq of parts, which need to be combined to the complete
  ## function at runtime
  let muIdx = argmax(hist)
  case tfKind
  of tfCuNi15:
    result.add FitFuncArgs(name: "Cu-Kalpha",
                           kind: ffGauss,
                           gN: hist[muIdx],
                           gmu: 1700.0e3, #binning[muIdx],
                           gs: hist[muIdx] * 1.5e3)
    result.add FitFuncArgs(name: "Cu-esc",
                           kind: ffGauss,
                           gN: hist[muIdx] / 10.0,
                           gmu: 1070.0e3, #binning[muIdx] / 2.0,
                           gs: hist[muIdx] * 1e3)
  of tfMnCr12:
    result.add FitFuncArgs(name: "Mn-Kalpha",
                           kind: ffGauss,
                           gN: hist[muIdx] / 4.0,
                           gmu: binning[muIdx],
                           gs: hist[muIdx] * 2.5e3)
    result.add FitFuncArgs(name: "Mn-esc",
                           kind: ffGauss,
                           gN: hist[muIdx] / 10.0,
                           gmu: binning[muIdx] / 2.0,
                           gs: hist[muIdx] * 1e3)
    #result.add FitFuncArgs(name: "p0",
    #                       kind: ffConst,
    #                       c: -hist[muIdx])
    #result.add FitFuncArgs(name: "p1",
    #                       kind: ffPol1,
    #                       cp: hist[muIdx])
    #result.add FitFuncArgs(name: "p2",
    #                       kind: ffPol2,
    #                       cpp: -hist[muIdx])
  of tfTiTi9:
    result.add FitFuncArgs(name: "Ti-Kalpha",
                           kind: ffGauss,
                           gN: hist[muIdx] / 2.0,
                           gmu: 1140.0, #binning[muIdx],
                           gs: hist[muIdx] * 1e3)
    result.add FitFuncArgs(name: "Ti-esc-alpha",
                           kind: ffGauss,
                           gN: hist[muIdx] / 10.0,
                           gmu: 400.0e3, #binning[muIdx],
                           gs: hist[muIdx] * 1e3)
    result.add FitFuncArgs(name: "Ti-esc-beta",
                           kind: ffGauss,
                           gN: hist[muIdx] / 10.0,
                           gmu: binning[muIdx] ,
                           gs: hist[muIdx] * 1e3)
    result.add FitFuncArgs(name: "Ti-Kbeta",
                           kind: ffGauss,
                           gN: hist[muIdx] / 2.0,
                           gmu: binning[muIdx], #* 1e5,
                           gs: hist[muIdx] * 1e3)
  of tfAgAg6:
    result.add FitFuncArgs(name: "Ag-Lalpha",
                           kind: ffGauss,
                           gN: hist[muIdx] / 2.0,
                           gmu: 800.0e3, #binning[muIdx],
                           gs: hist[muIdx] * 1e3)
    result.add FitFuncArgs(name: "Ag-Lbeta",
                           kind: ffGauss,
                           gN: hist[muIdx] / 2.0,
                           gmu: binning[muIdx],
                           gs: hist[muIdx] * 1.5e3)
    #result.add FitFuncArgs(name: "p0",
    #                       kind: ffConst,
    #                       c: -hist[muIdx])
    #result.add FitFuncArgs(name: "p1",
    #                       kind: ffPol1,
    #                       cp: hist[muIdx])
    #result.add FitFuncArgs(name: "p2",
    #                       kind: ffPol2,
    #                       cpp: -hist[muIdx])
  of tfAlAl4:
    result.add FitFuncArgs(name: "Ag-Kalpha",
                           kind: ffGauss,
                           gN: hist[muIdx] / 4.0,
                           gmu: 350.0e3,#binning[muIdx],
                           gs: hist[muIdx] * 1e3)
    #result.add FitFuncArgs(name: "p0",
    #                       kind: ffConst,
    #                       c: -hist[muIdx])
    #result.add FitFuncArgs(name: "p1",
    #                       kind: ffPol1,
    #                       cp: hist[muIdx])
    #result.add FitFuncArgs(name: "p2",
    #                       kind: ffPol2,
    #                       cpp: -hist[muIdx])
  of tfCuEpic2:
    result.add FitFuncArgs(name: "Cu-Lalpha",
                          kind: ffGauss,
                          gN: hist[muIdx] / 4.0,
                          gmu: binning[muIdx], #* 0.5e3,
                          gs: hist[muIdx] * 1e2)
    result.add FitFuncArgs(name: "Cu-Lbeta",
                          kind: ffGauss,
                          #ea: hist[muIdx] * 1e3, #* 1e-10,
                          #eb: hist[muIdx] * 1e3, #* 1e-12,
                          gN: hist[muIdx] / 4.0,
                          gmu: binning[muIdx],
                          gs: hist[muIdx] * 1e3)
  of tfCuEpic0_9:
    result.add FitFuncArgs(name: "O-Kalpha",
                          kind: ffGauss,
                          gN: hist[muIdx] / 4.0,
                          gmu: binning[muIdx],
                          gs: hist[muIdx] * 1e2)
    result.add FitFuncArgs(name: "C-Kalpha",
                          kind: ffGauss,
                          gN: hist[muIdx] / 4.0,
                          gmu: binning[muIdx],
                          gs: hist[muIdx] * 1e3)
  of tfCEpic0_6:
    result.add FitFuncArgs(name: "C-Kalpha",
                           kind: ffGauss,
                           gN: hist[muIdx] / 4.0,
                           gmu: binning[muIdx], #/ 2.0,
                           gs: hist[muIdx]  * 1e2)
    result.add FitFuncArgs(name: "O-Kalpha",
                           kind: ffGauss,
                           gN: hist[muIdx] / 4.0,
                           gmu: binning[muIdx], #* 1e3,
                           gs: hist[muIdx]  * 1e3)

proc genFitFuncImpl(idx: var int, xNode,
                    pFitNode: NimNode, paramsNode: seq[NimNode]): NimNode =
  ## the compile time procedure that creates the implementation lines for
  ## the <target><Filter>Funcs that we create, which calls the correct functions,
  ## e.g.
  ##   result += p_ar[i] * gauss(x, p[i + 1], p[i + 2])
  ##   inc i, 3
  let resultNode = ident"result"
  expectKind(pFitNode, nnkObjConstr)
  let fkind = parseEnum[FitFuncKind](pFitNode[2][1].strVal)
  case fKind
  of ffConst:
    let p0 = paramsNode[idx]
    result = quote do:
      `resultNode` += `p0`
    inc idx
  of ffPol1:
    let p0 = paramsNode[idx]
    result = quote do:
      `resultNode` += `p0` * `xNode`
    inc idx
  of ffPol2:
    let p0 = paramsNode[idx]
    result = quote do:
      `resultNode` += `p0` * `xNode` * `xNode`
    inc idx
  of ffGauss:
    let
      p0 = paramsNode[idx]
      p1 = paramsNode[idx + 1]
      p2 = paramsNode[idx + 2]
    result = quote do:
      `resultNode` += `p0` * gauss(`xNode`, `p1`, `p2`)
    inc idx, 3
  of ffExpGauss:
    let
      p0 = paramsNode[idx]
      p1 = paramsNode[idx + 1]
      p2 = paramsNode[idx + 2]
      p3 = paramsNode[idx + 3]
      p4 = paramsNode[idx + 4]
    result = quote do:
      `resultNode` += expGauss(@[`p0`, `p1`, `p2`, `p3`, `p4`], `xNode`)
    inc idx, 5

proc idOf(x: int): NimNode =
  let param = ident"p_ar"
  result = quote do:
    `param`[`x`]

proc drop(p: NimNode, frm: int): NimNode =
  result = copy(p)
  result.del(0, frm)
  echo result.treeRepr

proc resolveCall(tab: OrderedTable[string, NimNode],
                 n: NimNode): NimNode =
  expectKind(n, nnkCall)
  const paramIdent = "p_ar"
  if n[1].strVal == paramIdent:
    # call is an nnkOpenSymChoice from the `p_ar[x]`
    result = n
  else:
    # call is a reference to a different parameter
    let key = n[0].strVal & "_" & n[1].strVal
    result = tab[key]

proc resolveNodes(tab: OrderedTable[string, NimNode]): seq[NimNode] =
  ## resolve the potentially still ambiguous nodes (e.g. a reference to a
  ## parameter of a different line) and convert the `OrderedTable` into a
  ## serialized sequence of the nodes
  for k, v in tab:
    case v.kind
    of nnkCall:
      result.add resolveCall(tab, v)
    else:
      if v.len == 0:
        result.add v
      else:
        # have to walk the tree to replace references
        var node = copyNimTree(v)
        for i in 0 ..< node.len:
          case node[i].kind
          of nnkCall:
            # replace the call with the resolved node
            node[i] = resolveCall(tab, node[i])
          else:
            # else leave node unchanged
            discard
        result.add node

proc incAndFill(tab: var OrderedTable[string, NimNode],
                idx: var int, keyBase, lineName: string) =
  let key = keyBase & "_" & lineName
  if key notin tab:
    tab[key] = idOf(idx)
    inc idx
  else:
    # if key in the table, remove it and re-add so that the position
    # is the correct one in our OrderedTable!
    let tmp = tab[key]
    tab.del(key)
    tab[key] = tmp

proc fillParamsTable(tab: var OrderedTable[string, NimNode],
                     p: NimNode, idx: var int) =
  ## creates a table of NimNodes, which stores the NimNode that will show up
  ## in the created fitting procedure under a unique string, which consists
  ## of `FitParameter_LineName`. This table can then later be used to
  ## reference arbitrary parameters of the fitting functions in a different
  ## or same line
  # get the correct part of the parameters
  let fkind = parseEnum[FitFuncKind](p[2][1].strVal)
  #var cTab = initOrderedTable[string, NimNode]()
  var toReplace: NimNode
  let lineName = p[1][1].strVal
  if p.len > 3:
    # if p.len has more than 3 children, one ore more parameters have
    # been fixed to some constant or relative value. Fill the `tab` with
    # the NimNodes corresponding to those values
    toReplace = p.drop(3)
    for x in toReplace:
      case x[1].kind
      of nnkIdent, nnkIntLit .. nnkFloatLit, nnkInfix, nnkCall:
        let id = x[0].strVal & "_" & lineName
        tab[id] = x[1]
      else: error("Unsupported kind " & $x[1].kind)

  # Now walk over the table with the parameters of the current line
  # and either enter the correct `p_ar[idx]` field as the value in
  # the table or put the value to be replaced at the correct position
  # in the table
  case fKind
  of ffConst:
    incAndFill(tab, idx, "c", lineName)
  of ffPol1:
    incAndFill(tab, idx, "cp", lineName)
  of ffPol2:
    incAndFill(tab, idx, "cpp", lineName)
    inc idx
  of ffGauss:
    incAndFill(tab, idx, "gN", lineName)
    incAndFill(tab, idx, "gmu", lineName)
    incAndFill(tab, idx, "gs", lineName)
  of ffExpGauss:
    incAndFill(tab, idx, "ea", lineName)
    incAndFill(tab, idx, "eb", lineName)
    incAndFill(tab, idx, "eN", lineName)
    incAndFill(tab, idx, "emu", lineName)
    incAndFill(tab, idx, "es", lineName)

proc buildFitFunc(name, parts: NimNode): NimNode =
  ## builds a CDL fit function based on the function described by
  ## the `seq[FitFuncArgs]` at compile time. Using the `FitFuncKind` of
  ## each part, it'll write the needed implementation lines for the
  ## call to the correct functions, e.g. `gauss`, `expGauss` etc.
  # define the variables needed in the implementation function and
  # for the parameters
  let
    idx = ident"i"
    paramsNode = ident"p_ar"
    xNode = ident"x"
  # define parameters and return type of the proc we create
  let
    retType = ident"float"
    retParNode = nnkIdentDefs.newTree(paramsNode,
                                      nnkBracketExpr.newTree(
                                        ident"seq",
                                        ident"float"),
                                      newEmptyNode())
    retXNode = nnkIdentDefs.newTree(xNode,
                                    ident"float",
                                    newEmptyNode())
  # create a node to hold the procedure body
  var procBody = newStmtList()

  var i = 0
  var paramsTab = initOrderedTable[string, NimNode]()
  for p in parts:
    # create the table which maps the parameter of each line to the
    # correct NimNode. May either be
    # - `p_ar[idx]`
    # - some literal int / float
    # - some calculation involving a reference to some other parameter
    paramsTab.fillParamsTable(p, i)
  # now that we have the whole tableresolve all still remaining references
  # to other parameters
  let params = resolveNodes(paramsTab)
  i = 0
  for p in parts:
    procBody.add genFitFuncImpl(i, xNode, p, params)

  # now define the result variable as a new proc
  result = newProc(name = name,
                   params = [retType, retParNode, retXNode],
                   body = procBody,
                   procType = nnkFuncDef)

macro declareFitFunc(name, stmts: untyped): untyped =
  ## DSL to declare the fit functions without having to go the
  ## const of `seq[FitFuncArgs]` + buildFitFunc macro route.
  ##
  ## .. code-block::
  ##   declareFitFunc(cEpic):
  ##     ffGauss: "C-Kalpha"
  ##     ffGauss: "O-Kalpha"
  ##   # will be expanded to
  ##   var cEpicF {.compileTime.} = @[FitFuncArgs(name: "C-Kalpha", kind: ffGauss),
  ##                                  FitFuncArgs(name: "O-Kalpha", kind: ffGauss)]
  ##   buildFitFunc(cEpicFunc, cEpicF)

  let
    thVarId = ident(name.strVal & "F_Mangle")
    funcId = ident(name.strVal & "Func")
  var ffSeq = nnkBracket.newTree()

  for s in stmts:
    expectKind(s, nnkCall)
    echo s.treeRepr
    let fkind = s[0]
    case s[1].len
    of 1:
      let ffName = s[1][0].strVal
      ffSeq.add quote do:
        FitFuncArgs(name: `ffName`, kind: `fKind`)
    else:
      var ffName = ""
      var ffArg = nnkObjConstr.newTree(ident"FitFuncArgs")
      for x in s[1]:
        expectKind(x, nnkAsgn)
        if x[0].basename.ident == toNimIdent"name":
          ffArg.add nnkExprColonExpr.newTree(ident"name", x[1])
        else:
          ffArg.add nnkExprColonExpr.newTree(x[0], x[1])
      ffArg.insert(2, nnkExprColonExpr.newTree(ident"kind", fKind))
      ffSeq.add ffArg

  result = buildFitFunc(funcId, ffSeq)
  echo result.repr

declareFitFunc(cuNi15):
  ffGauss: "Cu-Kalpha"
    #name = "Cu-Kalpha"
    #ea = -8.305
    #eb = 0.08444
    #eN = 195.2
    #emu = 286.7
    #es = 16.23
  ffGauss: "Cu-esc"
    #name = "Cu-esc"
    #ea = -1.644
    #eb = 0.023
    #eN = 28.47
    #emu = 187.0
    #es = 13.5
declareFitFunc(cuNi15Charge):
  ffGauss: "Cu-Kalpha"
    #name = "Cu-Kalpha"
    #gN = 28.47
    #gmu = 187.0
    #gs = 13.5
  ffGauss: "Cu-esc"
    #name = "Cu-esc"
    #gN = 14.25
    #gmu = 1077142.2
    #gs = 113290.5
declareFitFunc(mnCr12):
  ffExpGauss: "Mn-Kalpha"
    #name = "Mn-Kalpha"
    #ea = -1.834
    #eb = 0.04455
    #emu = 200.3
    #es = 12.7
  ffGauss: "Mn-esc"
    #name = "Mn-esc"
    #ea = -0.06356
    #eb = 0.0467
    #emu = 102.1
    #es = 8.44
declareFitFunc(mnCr12Charge):
  ffGauss: "Mn-Kalpha"
  ffGauss: "Mn-esc"
  #ffConst: "p0"
  #ffPol1: "p1"
  #ffPol2: "p2"
declareFitFunc(tiTi9):
  ffGauss: "Ti-Kalpha"
  ffGauss: "Ti-esc-alpha"
  ffGauss: "Ti-esc-beta"
    #name = "Ti-esc-beta"
    #gmu = ??
    #gs = ??
  ffGauss: "Ti-Kbeta"
    #name = "Ti-Kbeta"
    #gmu = ??
    #gs = ??
declareFitFunc(tiTi9Charge):
  ffGauss: "Ti-Kalpha"
  ffGauss: "Ti-esc-aplha"
  ffGauss: "Ti-esc-beta"
  ffGauss: "Ti-Kbeta"
declareFitFunc(agAg6):
  ffGauss: "Ag-Lalpha"
  ffGauss: "Ag-Lbeta"
    #name = "Ag-Lbeta"
    #gmu = ??
    #gs = ??
declareFitFunc(agAg6Charge):
  ffGauss: "Ag-esc"
  ffGauss: "Ag-Kalpha"
  #ffConst: "p0"
  #ffPol1: "p1"
  #ffPol2: "p2"
declareFitFunc(alAl4):
  ffexpGauss: "Al-Kalpha"
declareFitFunc(alAl4Charge):
  ffGauss: "Al-Kalpha"
  #ffConst: "p0"
  #ffPol1: "p1"
  #ffPol2: "p2"
declareFitFunc(cuEpic2):
  ffGauss: "Cu-Lalpha"
  ffGauss: "Cu-Lbeta"
declareFitFunc(cuEpic2Charge):
  ffGauss: "Cu-Lalpha"
  ffGauss: "Cu-Lbeta"
declareFitFunc(cuEpic0_9):
  ffGauss: "O-Kalpha"
  ffGauss: "C-Kalpha"
  #ffExpGauss: "O-Lbeta"
    #name = "C-Kalpha"
    #gmu = ??
    #gs = ??
  #ffGauss: "Fe-Lalphabeta"
    #name = "Fe-Lalphabeta"
    #gmu = ??
    #gs = ??
  #ffGauss: "Ni-Lalphabeta"
    #name = "Ni-Lalphabeta"
    #gmu = ??
    #gs = ??
declareFitFunc(cuEpic0_9Charge):
  ffGauss: "O-Kalpha"
  ffGauss: "C-Kalpha"
declareFitFunc(cEpic0_6):
  ffGauss: "C-Kalpha"
  ffGauss: "O-Kalpha"
    #name = "O-Kalpha"
    #gmu = 15.0
    #gs = -12.0
declareFitFunc(cEpic0_6Charge):
  ffGauss: "C-Kalpha"
  ffGauss: "O-Kalpha"

func filterNaN(s: openArray[float]): seq[float] =
  result = newSeqOfCap[float](s.len)
  for x in s:
    if classify(x) != fcNaN:
      result.add x

proc serialize(parts: seq[FitFuncArgs]): seq[float] =
  for p in parts:
    case p.kind
    of ffConst:
      result.add filterNaN([p.c])
    of ffPol1:
      result.add filterNaN([p.cp])
    of ffPol2:
      result.add filterNaN([p.cpp])
    of ffGauss:
      result.add filterNaN([p.gN, p.gmu, p.gs])
    of ffExpGauss:
      result.add filterNaN([p.ea, p.eb, p.eN, p.emu, p.es])


macro genTfToFitFunc(pname: untyped): untyped =
  let tfkind = getType(TargetFilterKind)
  #first generate the string combinations
  var funcNames: seq[string]
  for x in tfKind:
    if x.kind != nnkEmpty:
      let xStr = ($(x.getImpl))
        .toLowerAscii
        .replace("-", "")
        .replace(".", "")
        .replace("kv", "")
      funcNames.add xStr
  #given the names, write a proc that returns the function
  let
    ##now with target and filter combined
    arg = ident"tfKind"
    argType = ident"TargetFilterKind"
    cdf = ident"CdlFitFunc"
    tfNameNode = ident"n"
    resIdent = ident"result"
  var caseStmt = nnkCaseStmt.newTree(tfNameNode)
  var caseStmtC = nnkCaseStmt.newTree(tfNameNode)
  for n in funcNames:
    let retId = ident($n & "Func")
    let retval = quote do:
      `resIdent` = `retId`
    caseStmt.add nnkOfBranch.newTree(newLit $retId, retval)
    let retIdC = ident($n & "ChargeFunc")
    let retvalC = quote do:
      `resIdent` = `retIdC`
    caseStmtC.add nnkOfBranch.newTree(newLit $retIdC, retvalC)
  let hitsname = pname
  let chargename = ident($pname & "Charge")
  result = quote do:
    proc `hitsname`(`arg`: `argType`): `cdf` =
      let `tfNameNode` = ($`arg`)
        .toLowerAscii
        .replace("-", "")
        .replace(".", "")
        .replace("kv", "") & "Func"
      `caseStmt`
    proc `chargename`(`arg`: `argType`): `cdf` =
      let `tfNameNode` = ($`arg`)
        .toLowerAscii
        .replace("-", "")
        .replace(".", "")
        .replace("kv", "") & "ChargeFunc"
      `caseStmtC`
  echo result.repr

# generate the =getCdlFitFunc= used to get the correct fit function
# based on a `TargetKind` and `FilterKind`
genTfToFitFunc(getCdlFitFunc)


proc histoCdl(data: seq[SomeNumber], binSize: float = 3.0, dKind: DataKind): (seq[float], seq[float]) =
  let low = -0.5 * binSize
  var high = max(data).float + (0.5 * binSize)
  let nbins = (ceil((high - low) / binSize)).round.int
  # using correct nBins, determine actual high
  high = low + binSize * nbins.float
  let bin_edges = linspace(low, high, nbins + 1)
  let hist = data.histogram(bins = nbins, range = (low, high))

  result[0] = hist.mapIt(it.float)
  case dKind
  of Dhits:
    result[1] = bin_edges[1 .. ^1]
  of Dcharge:
    result[1] = bin_edges[0 .. ^2]
  #echo "Bin edges len ", bin_edges.len
  #echo "Result len ", result[1].len


proc fitCdlImpl(hist, binedges: seq[float], tfKind: TargetFilterKind, dKind: DataKind):
               (seq[float], seq[float], seq[float]) =
  ##generates the fit paramter
  var lines: seq[FitFuncArgs]
  var fitfunc: CdlFitFunc
  case dKind
  of Dhits:
    lines = getLines(hist, binedges, tfKind)
    fitfunc = getCdlFitFunc(tfKind)
  of Dcharge:
    lines = getLinesCharge(hist, binedges, tfKind)
    fitfunc = getCdlFitFuncCharge(tfKind)

  let params = lines.serialize
  let cumu = cumsum(hist)
  let sum = sum(hist)
  let quotient = cumu.mapIt(it/sum)
  let lowIdx = quotient.lowerBound(0.0005)
  let highIdx = quotient.lowerBound(0.98)
  let passbin = binedges[lowIdx .. highIdx]
  let passhist = hist[lowIdx .. highIdx]

  let passIdx = toSeq(0 .. passhist.high).filterIt(passhist[it] > 0)
  let fitBins = passIdx.mapIt(passbin[it])
  let fitHist = passIdx.mapIt(passhist[it])
  let err = fitHist.mapIt(1.0)# / sqrt(it))

  let (pRes, res) = fit(fitfunc,
                        params,
                        fitBins,
                        fitHist,
                        err)

  echoResult(pRes, res=res)
  result = (pRes, fitBins, fitHist)

proc toCutStr(run: CdlRun): string =
  let hv = block:
    if run.hv > 1.0 and run.hv < 10.0:
      &"{run.hv:1}"
    elif run.hv > 10.0:
      &"{run.hv:2}"
    else:
      &"{run.hv:1.1f}"
  result = &"{run.target}-{run.filter}-{hv}kV"

proc readRuns(fname: string): seq[CdlRun] =
  var s = newFileStream(fname, fmRead)
  var parser: CsvParser
  if not s.isNil:
    parser.open(s, fname, separator = '|')
    parser.readHeaderRow()
    discard parser.readRow()
    while parser.readRow:
      let row = parser.row
      let run = CdlRun(number: row[1].strip.parseInt,
                       runType: parseEnum[RunTypeKind](row[2].strip, rtNone),
                       hasFadc: row[3].strip.parseBool,
                       target: parseEnum[TargetKind](row[4].strip, tEmpty),
                       filter: parseEnum[FilterKind](row[5].strip, fEmpty),
                       hv: if row[6].strip.len > 0: row[6].strip.parseFloat else: 0.0)
      result.add run


proc totfkind(run: CdlRun): TargetFilterKind =
  result = parseEnum[TargetFilterKind](&"{toCutStr(run)}")

proc main =

  let args = docopt(doc)
  let h5file = $args["<h5file>"]
  const filename = "../../resources/cdl_runs_2019.org"
  #const cutparams = "../../resources/cutparams.org"
  #actually cutparams isn't necessary since cuts are choosen in tos helpers
  let runs = readRuns(filename)
  var h5f = H5file(h5file, "rw")
  defer: discard h5f.close()
  let cutTab = getXraySpectrumCutVals()

  proc recoAndWrite (h5file: string) =
    for r in runs:
      #if r.number != 315:
        #continue
      sleep 500
      case r.runType
      of rtXrayFinger:
        let grp = h5f[(recoDataChipBase(r.number) & "3").grp_str]
        let cut = cutTab[r.toCutStr]
        let passIdx = cutOnProperties(h5f,
                                     grp,
                                     cut.cutTo,
                                     ("rmsTransverse", cut.minRms, cut.maxRms),
                                     ("length", 0.0, cut.maxLength),
                                     ("hits", cut.minPix, Inf),
                                     ("eccentricity", 0.0, cut.maxEccentricity))
        let nevents = passIdx.len

        proc writeDset(dsetWrite, dsetRead: string, datatype: typedesc) =
          var
            dset = h5f.create_dataset(grp.name / dsetWrite, (nevents, 1),
                                      datatype)
          if dsetWrite == "CdlSpectrumIndices":
            dset[dset.all] = passIdx
          else:
            let read = h5f[grp.name / dsetRead, datatype]
            dset[dset.all] = passIdx.mapIt(read[it])
          dset.attrs["Target"] = $r.target
          dset.attrs["Filter"] = $r.filter
          dset.attrs["HV"] = $r.hv
        writeDset("CdlSpectrumIndices", "", int64)
        writeDset("CdlSpectrum", "hits", int64)
        writeDset("CdlSpectrumEvents", "eventNumber", int64)
        writeDset("CdlSpectrumCharge", "totalCharge", float64)

        let runnum = h5f[(recoBase() & $r.number).grp_str]
        runnum.attrs["tfKind"] = $r.toCutStr
      else:
        discard

  recoAndWrite(h5file)

  proc fitAndPlot[T: SomeNumber](h5file: string, tfKind: TargetFilterKind, dKind: DataKind) =
    let targetFilter = tfkind
    var rawseq: seq[T]
    var cutseq: seq[T]
    var binsizeplot: float
    var binrangeplot: float
    var xtitle: string
    var filename: string
    var fitfunc: CdlFitFunc
    case dKind
    of Dhits:
      fitfunc = getCdlFitFunc(targetFilter)
      binsizeplot = 1.0
      binrangeplot = 400.0
      xtitle = "Number of pixles"
      filename = &"{tfKind}"
    of Dcharge:
      fitfunc = getCdlFitFuncCharge(targetFilter)
      binsizeplot = 10000.0
      binrangeplot = 3500000.0
      xtitle = "Charge"
      filename = &"{tfKind}Charge"

    for r in runs:
      #if r.number != 347:
        #continue
      sleep 500
      case r.runType
      of rtXrayFinger:
        let grp = h5f[(recoDataChipBase(r.number) & "3").grp_str]
        let tfk = r.totfkind
        if tfk == targetFilter:
          case dKind
          of Dhits:
            let RawDataSeq = h5f[grp.name / "hits", T]
            let Cdlseq = h5f[grp.name / "CdlSpectrum", T]
            rawseq.add(RawDataseq)
            cutseq.add(Cdlseq)
          of Dcharge:
            let RawDataSeq = h5f[grp.name / "totalCharge", T]
            let Cdlseq = h5f[grp.name / "CdlSpectrumCharge", T]
            rawseq.add(RawDataseq)
            cutseq.add(Cdlseq)
      else:
         discard
    proc calcfit(dataseq: seq[SomeNumber],
                 cdlFitFunc: CdlFitFunc,
                 binSize: float,
                 dKind: DataKind): (seq[float], seq[float], float, float) =
      let (histdata, bins) = histoCdl(dataseq, binSize, dKind)
      let (pRes, fitBins, fitHist) = fitCdlImpl(histdata, bins, targetFilter, dKind)
      fitForNlopt(convertNlopt, cdlFitFunc)
      var opt = newNloptOpt("LN_BOBYQA", pRes.len)
      var fitObj = FitObject(x: fitBins, y: fitHist, yErr: fitHist.mapIt(sqrt(it)))
      var vstruct = newVarStruct(convertNlopt, fitObj)
      opt.setFunction(vstruct)
      opt.xtol_rel = 1e-10
      opt.ftol_rel = 1e-10
      opt.maxtime  = 5.0
      let (paramsN, minN) = opt.optimize(pRes)
      nlopt_destroy(opt.optimizer)

      let minbin = fitBins.min
      let maxbin = fitBins.max

      result = (pRes, paramsN, minbin, maxbin)

    proc calcfitcurve(minbin: float, maxbin: float,
                      cdlFitFunc: CdlFitFunc,
                      fitparams: seq[float]): (seq[float], seq[float]) =
      let
        minvalue = minbin
        maxvalue = maxbin
        range = linspace(minvalue.float, maxvalue.float, 1500)
        yvals = range.mapIt(cdlFitFunc(fitparams, it))
      result = (range, yvals)

    #var hitresults: (seq[float], seq[float], float, float)
    let hitresults = calcfit(cutseq, fitfunc, binsizeplot, dKind)
    ##get the interesting fit params
    var lines: seq[FitFuncArgs]
    var fitmu: float
    var fitsig: float
    var museq: seq[float]
    var sigseq: seq[float]
    let (histdata, bins) = histoCdl(cutseq, binsizeplot, dKind)
    lines = getLines(histdata, bins, tfKind)
    #echo "lines ", lines[0].kind
    case lines[0].kind
    of ffGauss:
      fitmu = hitresults[1][1]
      fitsig = hitresults[1][2]
      museq.add(fitmu)
    of ffExpGauss:
      fitmu = hitresults[1][3]
      fitsig = hitresults[1][4]
      museq.add(fitmu)
    else:
      discard
    echo "fitmu ", fitmu
    echo "fitsig ", fitsig
    echo "fitmuseq ", museq

    let mpfitres = calcfitcurve(hitresults[2], hitresults[3], fitfunc, hitresults[0])
    let nloptres = calcfitcurve(hitresults[2], hitresults[3], fitfunc, hitresults[1])
    let cdlPlot = scatterPlot(mpfitres[0], mpfitres[1]).mode(PlotMode.Lines)
    let cdlPlotNlopt = scatterPlot(nloptres[0], nloptres[1]).mode(PlotMode.Lines)

    ##test of annotations
    #echo "testforparams ", testmu
    #echo test8
    #let teststring = test8.string
    #let testanno = Annotation(x: 350,
    #                          y: 100,
    #                          text: &"test: " & test8)

    ##plot of hits and charge
    let hitsRaw = histPlot(rawseq.mapIt(it.float64))
      .binSize(binsizeplot)
      .binRange(0.0, binrangeplot)
    let hitsCut = histPlot(cutseq.mapIt(it.float64))
      .binSize(binsizeplot)
      .binRange(0.0, binrangeplot)
    hitsRaw.layout.barMode = BarMode.Overlay
    let plt = hitsRaw.addTrace(hitsCut.traces[0])
      #.addTrace(cdlPlot.traces[0])
      .addTrace(cdlPlotNlopt.traces[0])
      .legendLocation(x = 0.8, y = 0.9)
      .legendBgColor(ColorTHGrau)
      .backgroundColor(ColorTHGrau)
      .gridColor(color())
    plt.layout.title = &"target: {targetFilter}"
    plt.layout.showlegend = true
    #plt.legendBgColor(ColorTB)
    plt.traces[1].opacity = 0.5
    plt.traces[0].name = "raw data"
    plt.traces[0].marker = Marker[float](color: @[ColorTGrau])
    plt.traces[1].name = "data with cuts"
    plt.traces[1].marker = Marker[float](color: @[ColorTDBlau])
    plt.traces[1].opacity = 1.0
    plt.traces[2].name = "fit curve nlopt"
    plt.traces[2].marker = Marker[float](color: @[ColorTGelb])
    plt.layout.yaxis.title = "Occurence"
    plt.layout.xaxis.title = xtitle
    #plt.layout.annotations.add [testanno]
    plt.show(&"{filename}-2019.svg")

    ##create a svg
    # let nodes = buildSvg:
    #   let size = 20
    #   svg(width=size, height=size, xmlns="http://www.w3.org/2000/svg", version="1.1"):
    #     for _ in 0 .. 1000:
    #       let x = random(size)
    #       let y = random(size)
    #       let radius = random(5)
    #       circle(cx=x, cy=y, r=radius, stroke="#111122", fill="#E0E0F0", `fill-opacity`=0.5)
    #
    # let xmlNodes = nodes.render.parseXml
    #
    # #echo xmlNodes
    # #echo xmlNodes.len
    #
    # let xmlPolya = loadXml "Mn-Cr-12kVCharge-2019.svg"
    # echo xmlPolya.len

    # let att = {"transform" : "translate(800, 400)"}.toXmlAttributes
    # var nnNew = newXmlTree("g", xmlNodes.mapIt(it), att)
    # for x in xmlNodes:
    #   nnNew.add x
    # var nnPNew = newElement("g")
    # for x in xmlPolya:
    #   nnPNew.add x
    #
    # for i in 0 ..< xmlPolya.len:
    #   xmlPolya.delete(0)
    #
    # xmlPolya.add nnPNew
    # xmlPolya.add nnNew
    # echo xmlPolya.len
    #
    # var f = open("test.svg", fmWrite)
    # f.write(xmlPolya)
    # f.close()


  for tfkind in TargetFilterKind:
  #fitAndPlot(h5file, tfCEpic0_6)
    #fitAndPlot(h5file, tfkind)
    fitAndPlot[int64](h5file, tfkind, Dhits)
    fitAndPlot[float64](h5file, tfkind, Dcharge)


when isMainModule:
  main()
