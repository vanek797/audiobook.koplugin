-- Whole-page text preparation and view identity. No document navigation here.
local Page = {}

function Page.parse(parser, text)
    local normalized = parser:normalizeText(text or "")
    local words = parser:parseWords(normalized)
    local parsed = { text = normalized, words = words, sentences = {}, http_page = true }
    if normalized == "" or #words == 0 then return parsed end
    for _, word in ipairs(words) do word.sentence_index = 1 end
    parsed.sentences[1] = {
        index = 1, text = normalized, start_pos = 1, end_pos = #normalized,
        words = words, end_type = "page", http_page = true,
    }
    return parsed
end

function Page.capture(plugin)
    local ui = plugin and plugin.ui
    local doc = ui and ui.document
    if not doc then return nil end
    if ui.rolling and doc.getCurrentPos then
        local ok, position = pcall(doc.getCurrentPos, doc)
        if ok and type(position) == "number" then return { doc = doc, position = position } end
    elseif ui.paging and ui.getCurrentPage then
        local ok, page = pcall(ui.getCurrentPage, ui)
        if ok and type(page) == "number" then return { doc = doc, page = page } end
    end
end

function Page.sameView(snapshot, plugin)
    local current = Page.capture(plugin)
    return snapshot ~= nil and current ~= nil and current.doc == snapshot.doc
        and current.position == snapshot.position and current.page == snapshot.page
end

function Page.suffix(parsed, word_index)
    if not parsed or not parsed.http_page or not parsed.words or #parsed.words == 0 then return nil end
    word_index = math.max(1, math.min(#parsed.words, math.floor(tonumber(word_index) or 1)))
    local word = parsed.words[word_index]
    return parsed.text:sub(word.start_pos)
end

return Page
