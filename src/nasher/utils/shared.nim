import os, strtabs, times
from strutils import unindent

from glob import walkGlob

type
  CommandResult* = tuple[output: TaintedString, exitCode: int]

proc help*(helpMessage: string, errorCode = QuitSuccess) =
  ## Quits with a formatted help message, sending errorCode
  quit(helpMessage.unindent(2), errorCode)

iterator walkSourceFiles*(sources: seq[string]): string =
  for source in sources:
    for file in glob.walkGlob(source):
      yield file

proc getTimeDiff*(a, b: Time): int =
  ## Compares two times and returns the difference in seconds. If 0, the files
  ## are the same age. If positive, a is newer than b. If negative, b is newer
  ## than a.
  (a - b).inSeconds.int

proc getTimeDiffHint*(file: string, diff: int): string =
  ## Returns a message stating whether file a is newer than, older than, or the
  ## same age as file b, based on the value of diff.
  if diff > 0: file & " is newer than the existing file"
  elif diff < 0: file & " is older than the existing file"
  else: file & " is the same age as the existing file"

proc fileOlder*(file: string, time: Time): bool =
  ## Checks whether file is older than a time. Only checks seconds since copying
  ## modification times results in unequal nanoseconds.
  if existsFile(file):
    getTimeDiff(time, file.getLastModificationTime) > 0
  else: true

proc fileNewer*(file: string, time: Time): bool =
  if existsFile(file):
    getTimeDiff(time, file.getLastModificationTime) < 0
  else: false

proc getNwnInstallDir*: string =
  when defined(Linux):
    getHomeDir() / ".local" / "share" / "Neverwinter Nights"
  else:
    getHomeDir() / "Documents" / "Neverwinter Nights"

template withDir*(dir: string, body: untyped): untyped =
  let curDir = getCurrentDir()
  try:
    setCurrentDir(dir)
    body
  finally:
    setCurrentDir(curDir)