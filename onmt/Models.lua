local function buildInputNetwork(opt, dicts, scores, pretrainedWords, fixWords)
  local wordEmbedding = onmt.WordEmbedding.new(dicts.words:size(), -- vocab size
                                               opt.word_vec_size,
                                               pretrainedWords,
                                               fixWords)

  local inputs
  local inputSize = opt.word_vec_size

  local multiInputs = #dicts.features > 0

  if multiInputs then
    inputs = nn.ParallelTable()
      :add(wordEmbedding)
  else
    inputs = wordEmbedding
  end

  -- Sequence with features.
  if #dicts.features > 0 then
    local featEmbedding = onmt.FeaturesEmbedding.new(dicts.features,
                                                     opt.feat_vec_exponent,
                                                     opt.feat_vec_size,
                                                     opt.feat_merge)
    inputs:add(featEmbedding)
    inputSize = inputSize + featEmbedding.outputSize
  end

  if #scores > 0 then
    local addScores = onmt.FeaturesEmbedding.new(scores)
    inputs:add(addScores)
    inputSize = inputSize + scores:size()
  end

  local inputNetwork

  if multiInputs then
    inputNetwork = nn.Sequential()
      :add(inputs)
      :add(nn.JoinTable(2))
  else
    inputNetwork = inputs
  end

  return inputNetwork, inputSize
end

local function buildEncoder(opt, dicts, scores)
  local inputNetwork, inputSize = buildInputNetwork(opt, dicts, scores, opt.pre_word_vecs_enc, opt.fix_word_vecs_enc)

  if opt.brnn then
    -- Compute rnn hidden size depending on hidden states merge action.
    local rnnSize = opt.rnn_size
    if opt.brnn_merge == 'concat' then
      if opt.rnn_size % 2 ~= 0 then
        error('in concat mode, rnn_size must be divisible by 2')
      end
      rnnSize = rnnSize / 2
    elseif opt.brnn_merge == 'sum' then
      rnnSize = rnnSize
    else
      error('invalid merge action ' .. opt.brnn_merge)
    end

    local rnn = onmt.LSTM.new(opt.layers, inputSize, rnnSize, opt.dropout, opt.residual)

    return onmt.BiEncoder.new(inputNetwork, rnn, opt.brnn_merge)
  else
    local rnn = onmt.LSTM.new(opt.layers, inputSize, opt.rnn_size, opt.dropout, opt.residual)

    return onmt.Encoder.new(inputNetwork, rnn)
  end
end

local function buildDecoder(opt, dicts, verbose)
  local inputNetwork, inputSize = buildInputNetwork(opt, dicts, opt.pre_word_vecs_dec, opt.fix_word_vecs_dec)

  local generator

  if #dicts.features > 0 then
    generator = onmt.FeaturesGenerator.new(opt.rnn_size, dicts.words:size(), dicts.features)
  else
    generator = onmt.Generator.new(opt.rnn_size, dicts.words:size())
  end

  if opt.input_feed == 1 then
    if verbose then
      _G.logger:info(" * using input feeding")
    end
    inputSize = inputSize + opt.rnn_size
  end

  local rnn = onmt.LSTM.new(opt.layers, inputSize, opt.rnn_size, opt.dropout, opt.residual)

  return onmt.Decoder.new(inputNetwork, rnn, generator, opt.input_feed == 1)
end

--[[ This is useful when training from a model in parallel mode: each thread must own its model. ]]
local function clonePretrained(model)
  local clone = {}

  for k, v in pairs(model) do
    if k == 'modules' then
      clone.modules = {}
      for i = 1, #v do
        table.insert(clone.modules, onmt.utils.Tensor.deepClone(v[i]))
      end
    else
      clone[k] = v
    end
  end

  return clone
end

local function loadEncoder(pretrained, clone)
  local brnn = #pretrained.modules == 2

  if clone then
    pretrained = clonePretrained(pretrained)
  end

  if brnn then
    return onmt.BiEncoder.load(pretrained)
  else
    return onmt.Encoder.load(pretrained)
  end
end

local function loadDecoder(pretrained, clone)
  if clone then
    pretrained = clonePretrained(pretrained)
  end

  return onmt.Decoder.load(pretrained)
end

return {
  buildEncoder = buildEncoder,
  buildDecoder = buildDecoder,
  loadEncoder = loadEncoder,
  loadDecoder = loadDecoder
}
