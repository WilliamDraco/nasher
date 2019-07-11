import os, osproc, sequtils, streams, strformat, strutils, tables, times

import glob

import nasher/options
import nasher/erf
import nasher/gff
import nasher/nwnsc

proc showHelp(kind: CommandKind) =
  let help =
    case kind
    of ckInit: helpInit
    of ckList: helpList
    of ckCompile: helpCompile
    of ckPack: helpPack
    of ckUnpack: helpUnpack
    of ckInstall: helpInstall
    else: helpAll

  echo help
  echo helpOptions

proc unpack(opts: Options) =
  let
    dir = opts.cmd.dir
    file = opts.cmd.file.expandFilename
    cacheDir = file.getCacheDir(dir)

  if not existsFile(file):
    fatal(fmt"Cannot unpack file {file}: file does not exist")

  tryOrQuit(fmt"Could not create directory {cacheDir}"):
    createDir(cacheDir)

  withDir(cacheDir):
    extractErf(file, cacheDir)

  for ext in GffExtensions:
    createDir(dir / ext)
    for file in walkFiles(cacheDir / "*".addFileExt(ext)):
      gffConvert(file, dir / ext)

  createDir(dir / "nss")
  for file in walkFiles(cacheDir / "*".addFileExt("nss")):
    copyFileWithPermissions(file, dir / "nss" / file.extractFilename())

proc init(opts: var Options) =
  let
    dir = opts.cmd.dir
    pkgCfgFile = dir / "nasher.cfg"

  if existsFile(pkgCfgFile):
    fatal(fmt"{dir} is already a nasher project")

  display("Initializing", "into " & dir)
  opts.configs.add(pkgCfgFile)
  opts.cfg.loadConfig(pkgCfgFile)
  success("project initialized")

  if opts.cmd.file.len() > 0:
    opts.cmd.dir = getSrcDir(dir)
    unpack(opts)

proc list(opts: Options) =
  tryOrQuit("No targets found. Please check your nasher.cfg."):
    if isLogging(LowPriority):
      var hasRun = false
      for target in opts.cfg.targets.values:
        if hasRun:
          stdout.write("\n")
        display("Target:", target.name)
        display("Description:", target.description)
        display("File:", target.file)
        display("Sources:", target.sources.join("\n"))
        hasRun = true
    else:
      echo toSeq(opts.cfg.targets.keys).join("\n")

proc getTarget(opts: Options): Target =
  ## Returns the target specified by the user, or the first target found in the
  ## parsed config files if the user did not specify a target.
  try:
    if opts.cmd.target.len > 0:
      result = opts.cfg.targets[opts.cmd.target]
    else:
      for target in opts.cfg.targets.values:
        return target
  except IndexError:
    fatal("No targets found. Please check your nasher.cfg file.")
  except KeyError:
    fatal("Unknown target: " & opts.cmd.target)

proc copySourceFiles(target: Target, dir: string): string =
  ## Copies all source files for target to dir. Returns the newest source file
  withDir(getPkgRoot()):
    for source in target.sources:
      debug("Copying", "source files from " & source)
      for file in glob.walkGlob(source):
        debug("Copying", file)
        try:
          if file.fileNewer(result):
            debug(fmt"{file} is newer than {result}")
            result = file
        except OSError:
          # This is the first source file
          result = file
        copyFile(file, dir / file.extractFilename)

proc compile(dir, compiler, flags: string) =
  withDir(dir):
    var isScripts = false
    for file in walkFiles("*.nss"):
      isScripts = true
      break

    if isScripts:
      let errcode = runCompiler(compiler, [flags, "*.nss"])
      if errcode != 0:
        warning("Finished with error code " & $errcode)
    else:
      info("Skipping", "compilation: nothing to compile")

proc convert(dir: string) =
  withDir(dir):
    for file in walkFiles("*.*.json"):
      file.gffConvert
      file.removeFile

proc confirmOverwrite(time: Time, file: string): bool =
  ## Asks the user to confirm overwriting a file to be installed or packed. If
  ## the file is newer than time, default to no; otherwise, default to yes.
  ## Returns the user response.
  if not existsFile(file):
    return true

  let
    timeDiff = (time - file.getLastModificationTime).inSeconds

  var
    defaultAnswer = Yes
    ageHint: string

  if timeDiff > 0:
    ageHint = "newer than"
  elif timeDiff == 0:
    ageHint = "the same age as"
  else:
    ageHint = "older than"
    defaultAnswer = No

  hint(fmt"The source file is {ageHint} the existing file.")
  askIf(fmt"{file} already exists. Overwrite?", defaultAnswer)

proc copyModificationTime(target, src: string) =
  target.setLastModificationTime(src.getLastModificationTime)

proc install (file, dir: string) =
  display("Installing", file & " into " & dir)
  if not existsFile(file):
    fatal(fmt"Cannot install {file}: file does not exist")

  let
    fileTime = file.getLastModificationTime
    fileName = file.extractFilename
    installDir = expandTilde(
      case fileName.splitFile.ext.strip(chars = {'.'})
      of "erf": dir / "erf"
      of "hak": dir / "hak"
      of "mod": dir / "modules"
      else: dir)

  if not existsDir(installDir):
    fatal(fmt"Cannot install to {installDir}: directory does not exist")

  let installed = installDir / fileName
  if confirmOverwrite(fileTime, installed):
    copyFile(file, installed)
    installed.copyModificationTime(file)
    success("installed " & fileName)

proc pack(opts: Options) =
  let
    target = getTarget(opts)
    buildDir = getBuildDir(target.name)

  removeDir(buildDir)
  createDir(buildDir)
  let
    newestSource = copySourceFiles(target, buildDir)
    fileTime = newestSource.getLastModificationTime

  if opts.cmd.kind in {ckInstall, ckPack, ckCompile}:
    compile(buildDir, opts.cfg.compiler.binary, opts.cfg.compiler.flags.join(" "))

  if opts.cmd.kind in {ckInstall, ckPack}:
    convert(buildDir)

    display("Packing", fmt"files for target {target.name} into {target.file}")
    if not confirmOverwrite(fileTime, target.file):
      quit(QuitSuccess)

    let
      # sourceFiles = toSeq(walkFiles(buildDir / "*"))
      sourceFiles = @[buildDir / "*"]
      error = createErf(getPkgRoot() / target.file, sourceFiles)

    if error == 0:
      success("packed " & target.file)
      target.file.copyModificationTime(newestSource)
    else:
      fatal("Something went wrong!")

  if opts.cmd.kind == ckInstall:
    install(target.file, opts.cfg.user.install)

when isMainModule:
  var opts = parseCmdLine()

  if opts.showHelp:
    showHelp(opts.cmd.kind)
  else:
    if opts.cmd.kind != ckNil:
      if opts.cmd.kind != ckInit and not isNasherProject():
        fatal("This is not a nasher project. Please run nasher init.")

      opts.cfg = loadConfigs(opts.configs)

    case opts.cmd.kind
    of ckList: list(opts)
    of ckInit: init(opts)
    of ckUnpack: unpack(opts)
    of ckCompile, ckPack, ckInstall: pack(opts)
    of ckNil: echo nasherVersion
