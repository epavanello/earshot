#!/bin/bash
# Installs the Play shortcut in Hammerspoon: tap left Shift twice (within 0.4 s, nothing else held)
# to read the next queued line, again while it speaks to skip to the one after; and Esc to drop the
# line being read. Hammerspoon already has the permission to see keys; the watcher
# lives in its memory, so it is installed again at each session start (it does not survive a reload).
HS="$(command -v hs || ls /opt/homebrew/bin/hs /usr/local/bin/hs 2>/dev/null | head -n 1)"
[ -z "$HS" ] && exit 0
PLAYER="$(cd "$(dirname "$0")" && pwd)/player.sh"
STOP="$(cd "$(dirname "$0")" && pwd)/stop.sh"
# alarm: a Hammerspoon that does not answer must not hold the session start.
perl -e 'alarm 10; exec @ARGV' "$HS" -c "
if earshotPlay then earshotPlay:stop() end
local lastTap, wasDown = 0, false
earshotPlay = hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, function(e)
  if e:getKeyCode() ~= 56 then wasDown = false; return false end
  local flags = e:getFlags()
  local isDown = flags.shift and not (flags.cmd or flags.alt or flags.ctrl or flags.fn)
  if wasDown and not isDown then
    local now = hs.timer.secondsSinceEpoch()
    if now - lastTap < 0.4 then
      lastTap = 0
      hs.task.new('/bin/bash', nil, {'$PLAYER', '--one'}):start()
    else
      lastTap = now
    end
  end
  wasDown = isDown
  return false
end):start()
-- Esc while speaking: drop the line being read, keep the queue. Replaces the AirPods remote's own
-- watcher of the same name, which drops the whole queue in older builds.
if earshotEsc then earshotEsc:stop() end
earshotEsc = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(e)
  if e:getKeyCode() == 53 and hs.fs.attributes('/tmp/earshot.speaking') then
    hs.task.new('/bin/bash', nil, {'$STOP'}):start()
  end
  return false
end):start()
" >/dev/null 2>&1 &
exit 0
