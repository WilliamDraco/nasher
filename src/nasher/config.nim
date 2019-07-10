import os, osproc, parsecfg, streams, strformat, strutils, tables

import common
export common

type
  Config* = object
    user*: User
    pkg*: Package
    compiler*: tuple[binary: string, flags: seq[string]]
    targets*: OrderedTable[string, Target]

  User* = tuple[name, email, install: string]

  Compiler* = tuple[binary: string, flags: seq[string]]

  Package* = object
    name*, description*, version*, url*: string
    authors*: seq[string]

  Target* = object
    name*, file*, description*: string
    sources*: seq[string]

proc addLine(s: var string, line: string) =
  s.add(line & "\n")

proc addPair(s: var string, key, value: string) =
  s.addLine("$1 = \"$2\"" % [key, value])

proc genGlobalCfgText:string =
  let
    defaultName = execCmdOrDefault("git config --get user.name").strip
    defaultEmail = execCmdOrDefault("git config --get user.email").strip

  display("Generating", "global config file")
  display("Hint:", "The following options will be automatically filled into " &
          "the authors section of new packages created using nasher init:")
  let
    name = ask("What is your name?", defaultName)
    email = ask("What is your email?", defaultEmail)

  display("Hint:", "The following will be used to compile and install packages:")
  let
    install = ask("Where is your Neverwinter Nights installation located?", getNwnInstallDir())
    binary = ask("What is the command to run your script compiler?", "nwnsc")
    flags = ask("What script compiler flags should always be used?", "-lowqey")

  result.addLine("[User]")
  result.addPair("name", name)
  result.addPair("email", email)
  result.addPair("install", install)
  result.addLine("\n[Compiler]")
  result.addPair("binary", binary)

  for flag in flags.split:
    result.addPair("flags", flag)

proc genTargetText(defaultName: string): string =
  result.addLine("[Target]")
  result.addPair("name", ask("Target name:", defaultName))
  result.addPair("file", ask("File to generate:", "demo.mod"))
  result.addPair("description", ask("File description:"))

  display("Hint:", "you can list individual source files or specify glob " &
          "patterns that match multiple files.")
  var
    defaultSrc = "src/*.{nss,json}"
  while true:
    result.addPair("source", ask("Source pattern:", defaultSrc, allowBlank = false))
    defaultSrc = ""
    if not askIf("Do you wish to add another source pattern? (y/N)"):
      break

proc genPkgCfgText(user: User): string =
  display("Generating", "package config file")

  let
    defaultUrl = execCmdOrDefault("git remote get-url origin").strip

  result.addLine("[Package]")
  result.addPair("name", ask("Enter your package name"))
  result.addPair("description", ask("Package description:"))
  result.addPair("version", ask("Package version", "0.1.0"))
  result.addPair("url", ask("Package URL:", defaultUrl))

  var
    defaultAuthor = user.name
    defaultEmail = user.email

  while true:
    let
      authorName = ask("Author name:", defaultAuthor, allowBlank = false)
      authorEmail = ask("Author email:", defaultEmail)

    if authorEmail.isNilOrWhitespace:
      result.addPair("author", authorName)
    else:
      result.addPair("author", "$1 <$2>" % [authorName, authorEmail])

    if not askIf("Do you wish to add another author? (y/N)"):
      break

    defaultAuthor = ""
    defaultEmail = ""

  display("Hint:", "generating targets")

  var targetName = "default"
  while true:
    result.add("\n")
    result.add(genTargetText(targetName))
    targetName = ""

    if not askIf("Do you wish to add another target? (y/N)"):
      break

proc writeCfgFile(fileName, text: string) =
  tryOrQuit("Could not create config file at " & fileName):
    display("Creating", "configuration file at " & fileName)
    createDir(fileName.splitFile().dir)
    writeFile(fileName, text)

proc genCfgFile(file: string, user: User) =
  if file == getGlobalCfgFile():
    writeCfgFile(file, genGlobalCfgText())
  else:
    writeCfgFile(file, genPkgCfgText(user))

proc initConfig*(): Config =
  result.user.install = getNwnInstallDir()
  result.compiler.binary = "nwnsc"

proc initTarget(): Target =
  result.name = ""

proc addTarget(cfg: var Config, target: Target) =
  if target.name.len() > 0:
    cfg.targets[target.name] = target

proc parseUser(cfg: var Config, key, value: string) =
  case key
  of "name": cfg.user.name = value
  of "email": cfg.user.email = value
  of "install": cfg.user.install = value
  else:
    error(fmt"Unknown key/value pair '{key}={value}'")

proc parseCompiler(cfg: var Config, key, value: string) =
  case key
  of "binary": cfg.compiler.binary = value
  of "flags": cfg.compiler.flags.add(value)
  else:
    error(fmt"Unknown key/value pair '{key}={value}'")

proc parsePackage(cfg: var Config, key, value: string) =
  case key
  of "name": cfg.pkg.name = value
  of "description": cfg.pkg.description = value
  of "version": cfg.pkg.version = value
  of "author": cfg.pkg.authors.add(value)
  of "url": cfg.pkg.url = value
  else:
    error(fmt"Unknown key/value pair '{key}={value}'")

proc parseTarget(target: var Target, key, value: string) =
  case key
  of "name": target.name = value.normalize
  of "description": target.description = value
  of "file": target.file = value
  of "source": target.sources.add(value)
  else:
    error(fmt"Unknown key/value pair '{key}={value}'")

proc parseConfig*(cfg: var Config, fileName: string) =
  var f = newFileStream(fileName)
  if isNil(f):
    fatal(fmt"Cannot open config file: {fileName}")
    quit(QuitFailure)

  debug("File:", fileName)
  var p: CfgParser
  var section, key: string
  var target: Target
  p.open(f, fileName)
  while true:
    var e = p.next()
    case e.kind
    of cfgEof: break
    of cfgSectionStart:
      cfg.addTarget(target)

      debug("Section:", fmt"[{e.section}]")
      section = e.section.normalize
      target = initTarget()

    of cfgKeyValuePair, cfgOption:
      key = e.key.normalize
      debug("Option:", fmt"{key}: {e.value}")
      tryOrQuit(fmt"Error parsing {fileName}: {getCurrentExceptionMsg()}"):
        case section
        of "user":
          parseUser(cfg, key, e.value)
        of "compiler":
          parseCompiler(cfg, key, e.value)
        of "package":
          parsePackage(cfg, key, e.value)
        of "target":
          parseTarget(target, key, e.value)
        else:
          discard
    of cfgError:
      fatal(e.msg)
  cfg.addTarget(target)
  p.close()

proc dumpConfig(cfg: Config) =
  if not isLogging(DebugPriority):
    return

  sandwich:
    debug("Beginning", "configuration dump")

  debug("User:", cfg.user.name)
  debug("Email:", cfg.user.email)
  debug("Compiler:", cfg.compiler.binary)
  debug("Flags:", cfg.compiler.flags.join("\n"))
  debug("NWN Install:", cfg.user.install)
  debug("Package:", cfg.pkg.name)
  debug("Description:", cfg.pkg.description)
  debug("Version:", cfg.pkg.version)
  debug("URL:", cfg.pkg.url)
  debug("Authors:", cfg.pkg.authors.join("\n"))

  for target in cfg.targets.values:
    stdout.write("\n")
    debug("Target:", target.name)
    debug("Description:", target.description)
    debug("File:", target.file)
    debug("Sources:", target.sources.join("\n"))

  sandwich:
    debug("Ending", "configuration dump")


proc loadConfigs*(configs: seq[string]): Config =
  result = initConfig()
  var hasRun = false
  for config in configs:
    doAfterDebug(hasRun):
      stdout.write("\n")
    if not existsFile(config):
      genCfgFile(config, result.user)

    result.parseConfig(config)
  result.dumpConfig()
