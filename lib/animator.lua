local constants = include('lib/constants')
local STEP_NUM = constants.GRID_HEIGHT*constants.GRID_LENGTH
local GRID_LEVELS = constants.GRID_LEVELS
local INTERSECT_OPS = constants.INTERSECT_OPS
local helpers = include('lib/helpers')
local findPosition = helpers.findPosition
local copyTable = helpers.copyTable
local deepcopy = helpers.deepcopy
local Sequencer = include('lib/Sequencer')
local MusicUtil = require 'musicutil'
local BeatClock = require 'beatclock'
local MAX_SEQ_NUM = 8

function initStepState()
  local steps = {}
  for i=1,STEP_NUM do steps[i] = 0 end
  return steps
end

local animator = {}

animator.clock = BeatClock.new()
animator.noteOffMetro = metro.init()
animator.original = {}
animator.stepLevels = {}
animator.redraw = function() end
animator.on = initStepState()
animator.enabled = initStepState()
animator.sequencers = {}
animator.snapshots = {}
animator.shouldResetAll = false
animator.lastReplaced = 0
animator.showIntroText = true
animator.midiDevice = nil
animator.midiChannel = nil
animator.activeNotes = {}

function updateEnabled(steps)
  for i=1,#steps do
    local step = steps[i]
    local pos = findPosition(step.x, step.y)
    animator.enabled[pos] = animator.enabled[pos] + 1
  end
end

function updateOnState(steps)
  for i=1,#steps do
    local step = steps[i]
    local pos = findPosition(step.x, step.y)
    if animator.on[pos] > 0 then
      animator.on[pos] = animator.enabled[pos]
    end
  end
end

function animator.addNewSequence(steps)
  local index
  if #animator.sequencers == MAX_SEQ_NUM then
    animator.lastReplaced = animator.lastReplaced % MAX_SEQ_NUM + 1
    index = animator.lastReplaced
  else
    index = #animator.sequencers+1
  end
  if animator.showIntroText then animator.showIntroText = false end
  animator.sequencers[index] = Sequencer.new{steps = steps, index = index}
  updateEnabled(steps)
  updateOnState(steps)
end

local Snapshot = {}
function Snapshot.new(animator)
  local snapshot = {
    sequencers = animator.sequencers,
    on = animator.on,
    enabled = animator.enabled,
  }

  return snapshot
end

-- todo: does each note need its own metro?
function animator.allNotesOff()
  for _,channelNote in pairs(animator.activeNotes) do
    animator.midiDevice:note_off(channelNote.note, nil, channelNote.channel)
    engine.noteOff(channelNote.note)
  end
  animator.activeNotes = {}
end

function animator.count()
  local play = {}
  local findPos = findPosition
  local noteOn = engine.noteOn
  local numToFreq = MusicUtil.note_num_to_freq
  local random = math.random
  local slop = params:get('slop')
  local metroInit = metro.init

  local function playNote(note, channel)
    animator.midiDevice:note_on(note, random(1, 127), channel)
    noteOn(note, numToFreq(note), random(127)/127)
    animator.activeNotes[#animator.activeNotes+1] = {channel = channel, note = note}
    animator.noteOffMetro:start(params:get('note_length'), 1)
  end

  local function delayNote(note, channel)
    local delay = metroInit()
    delay.event = function()
      playNote(note, channel)
      metro.free(delay.id)
    end
    delay.time = random(slop)/1000
    delay.count = 1
    delay:start()
  end

  for i=1,#animator.sequencers do
    local seq = animator.sequencers[i]
    seq.divCount = seq.divCount % seq.div + 1
    if seq.divCount == 1 then
      seq.index = seq.index % seq.length + 1
      if animator.shouldResetAll then
        seq.index = 1
      end
      if seq.reset then
        seq.index = 1
        seq.reset = false
      end
      local currentStep = seq.steps[seq.index]
      local pos = findPos(currentStep.x, currentStep.y)
      if animator.on[pos] > 0 then
        if play[pos] == nil then
          play[pos] = {seq}
        else
          play[pos][#play[pos]+1] = seq
        end
      end
    end
  end

  if animator.shouldResetAll then animator.shouldResetAll = false end

  local maxNotes = params:get('max_notes')
  local noteCount = 0
  local notesPlayed = {}
  local channelNotes = {}

  for pos,seqs in pairs(play) do
    local note = animator.notes[pos]
    local channel = seqs[1].channel
    local channelNotes = {}
    channelNotes[channel] = note
    local mute = false
    local seqNum = #seqs
    if seqNum > 1 then
      for i=1,seqNum do
        channelNotes[seqs[i].channel] = note
        local intersect = INTERSECT_OPS[seqs[i].intersect]
        if intersect == constants.INTERSECT_OP_OCTAVE then
          note = note + 12
        elseif intersect == constants.INTERSECT_OP_MUTE then
          mute = true
        elseif intersect == constants.INTERSECT_OP_RESET_SELF then
          seqs[i].reset = true
        elseif intersect == constants.INTERSECT_OP_RESET_OTHER then
          for j=1,seqNum do if j~= i then seqs[j].reset = true end end
        elseif intersect == constants.INTERSECT_OP_RESET_ALL then
          animator.shouldResetAll = true
        end
      end
    end

    for channel,note in pairs(channelNotes) do
      if not mute and notesPlayed[note] ~= channel then
        if slop > 0 then
          delayNote(note, channel)
        else
          playNote(note, channel)
        end
        notesPlayed[note] = channel
        noteCount = noteCount+1
        if noteCount == maxNotes then
          return animator.redraw()
        end
      end
    end
  end

  animator.redraw()
end

function moveSteps(steps, axis, delta, wrap)
  clearStepState(steps)
  local newOn = {}

  for i=1,#steps do
    local step = steps[i]
    local pos = findPosition(step.x, step.y)
    step[axis] = (step[axis] + delta - 1) % wrap + 1
    if animator.on[pos] > 0 then
      newOn[findPosition(step.x, step.y)] = 1
    end
  end

  updateEnabled(steps)
  return newOn
end

function moveStepsPos(index, axis, val, wrap)
  local steps = animator.sequencers[index].steps
  clearStepState(steps)
  local newOn = {}

  local original = animator.original
  if not original[index] then original[index] = deepcopy(steps) end
  local originalSteps = original[index]
  local findPos = findPosition

  for i=1,#steps do
    local step = steps[i]
    local pos = findPos(step.x, step.y)
    step[axis] = (originalSteps[i][axis] + val - 1) % wrap + 1
    if animator.on[pos] > 0 then
      newOn[pos] = -1
      newOn[findPos(step.x, step.y)] = 1
    end
  end

  updateEnabled(steps)
  return newOn
end

function animator.moveSequencers(axis, delta, wrap)
  local newOn = {}
  for i=1,#animator.sequencers do
    local resp = moveSteps(animator.sequencers[i].steps, axis, delta, wrap)
    animator.sequencers[i]:regenStepMap()
    for pos,n in pairs(resp) do newOn[pos] = n end
  end
  for pos,n in pairs(animator.on) do
    if newOn[pos] ~= nil then
      animator.on[pos] = animator.enabled[pos]
    else
      animator.on[pos] = 0
    end
  end
end

function animator.moveSequencersPos(axis, val, wrap)
  local newOn = {}
  for i=1,#animator.sequencers do
    local resp = moveStepsPos(i, axis, val, wrap)
    animator.sequencers[i]:regenStepMap()
    for pos,n in pairs(resp) do newOn[pos] = n end
  end
  for pos,_ in pairs(animator.on) do
    if newOn[pos] == 1 then
      animator.on[pos] = animator.enabled[pos]
    else
      animator.on[pos] = 0
    end
  end
end

function animator.createNewSnapshot(i)
  if animator.snapshots[i] == nil then
    animator.snapshots[i] = Snapshot.new(animator)
  end

  setToSnapshot(animator.snapshots[i])
end

function setToSnapshot(snapshot)
  animator.on = copyTable(snapshot.on)
  animator.enabled = copyTable(snapshot.enabled)
  animator.sequencers = deepcopy(snapshot.sequencers)
end

function animator.clearSeq(index)
  clearStepState(animator.sequencers[index].steps)
  clearOnState(animator.sequencers[index].steps)
  table.remove(animator.sequencers, index)
  if not animator.sequencers[index+1] then resetSeqParams(index+1) end
  animator.redraw()
end

function resetSeqParams(index)
  params:set('seq' .. index .. 'div', 1)
  params:set('seq' .. index .. 'intersect', 1)
end

function animator.clear(view)
  if view == 1 then
    animator.sequencers = {}
    animator.snapshots = {}
    animator.original = {}
    animator.on = initStepState()
    animator.enabled = initStepState()
  else
    animator.clearSeq(animator.grid.selected)
  end
end

function animator.reset(view)
  if view == 1 then
    for i=1,#animator.sequencers do
      animator.sequencers[i].divCount = 1
      animator.sequencers[i].index = 1
    end
  else
    animator.sequencers[animator.grid.selected].reset = true
  end
end

function animator.resetStepLevels()
  animator.stepLevels = getStepLevels()
end

function animator.setStepLevels(seq)
  animator.stepLevels = seq and reduceStepLevels(seq) or {}
end

function reduceStepLevels(seq, levels)
  levels = levels or {}
  local steps = seq.steps
  local findPos = findPosition
  local max = math.max
  for i=1,#steps do
    local step = steps[i]
    local pos = findPos(step.x, step.y)
    -- step activated
    if animator.on[pos] > 0 then
      if i == seq.index then
        levels[pos] = GRID_LEVELS.HIGH
      else
        levels[pos] = levels[pos] == nil
                and GRID_LEVELS.MED
                or max(levels[pos], GRID_LEVELS.MED)
      end
      -- step highlighted but not activated
    elseif i == seq.index then
      levels[pos] = levels[pos] == nil
              and GRID_LEVELS.LOW_MED
              or max(levels[pos], GRID_LEVELS.LOW_MED)
      -- step not highlighted or activated
    else
      levels[pos] = levels[pos] == nil
              and GRID_LEVELS.DIM
              or max(levels[pos], GRID_LEVELS.DIM)
    end
  end

  return levels
end

function getStepLevels()
  local levels = {}
  for i=1,#animator.sequencers do
    reduceStepLevels(animator.sequencers[i], levels)
  end
  return levels
end

function clearStepState(steps)
  for i=1,#steps do
    local step = steps[i]
    local pos = findPosition(step.x, step.y)
    animator.enabled[pos] = animator.enabled[pos] - 1
  end
end

function clearOnState(steps)
  for i=1,#steps do
    local step = steps[i]
    local pos = findPosition(step.x, step.y)
    if animator.on[pos] > 0 then
      animator.on[pos] = animator.enabled[pos]
    end
  end
end

return animator
