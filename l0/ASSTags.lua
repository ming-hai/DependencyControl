local re = require("aegisub.re")
local unicode = require("aegisub.unicode")
local util = require("aegisub.util")
local l0Common = require("l0.Common")
local Line = require("a-mo.Line")
local LineCollection = require("a-mo.LineCollection")
local Log = require("a-mo.Log")
local ASSInspector = require("ASSInspector.Inspector")

local YUtilsMissingMsg, YUtils = [[Error: this method requires Yutils, but the module was not found.
Get it at https://github.com/Youka/Yutils]]
HAVE_YUTILS, YUtils = pcall(require, "YUtils")

local assertEx = assertEx

local function createASSClass(typeName, baseClasses, order, types, tagProps, compatibleClasses)
    if not baseClasses or type(baseClasses)=="table" and baseClasses.instanceOf then
        baseClasses = {baseClasses}
    end
    local cls, compatibleClasses = {}, compatibleClasses or {}

    -- write base classes set and import class members
    cls.baseClasses = {}
    for i=1,#baseClasses do
        for k, v in pairs(baseClasses[i]) do
            cls[k] = v
        end
        cls.baseClasses[baseClasses[i]] = true
    end

    -- object constructor
    setmetatable(cls, {
    __call = function(cls, ...)
        local self = setmetatable({__tag = util.copy(cls.__defProps)}, cls)
        self = self:new(...)
        return self
    end})

    cls.__index, cls.instanceOf, cls.typeName, cls.class = cls, {[cls] = true}, typeName, cls
    cls.__meta__ = {order = order, types = types}
    cls.__defProps = table.merge(cls.__defProps or {},tagProps or {})

    -- compatible classes
    cls.compatible = table.arrayToSet(compatibleClasses)
    -- set mutual compatibility in reference classes
    for i=1,#compatibleClasses do
        compatibleClasses[i].compatible[cls] = true
    end
    cls.compatible[cls] = true

    cls.getRawArgCnt = function(self)
        local cnt, meta = 0, self.__meta__
        if not meta.types then return 0 end
        for i=1,#meta.types do
            cnt = cnt + (type(meta.types[i])=="table" and meta.types[i].class and meta.types[i]:getRawArgCnt() or 1)
        end
        return cnt
    end
    cls.__meta__.rawArgCnt = cls:getRawArgCnt()

    return cls
end

--------------------- Base Class ---------------------

ASSBase = createASSClass("ASSBase")
function ASSBase:checkType(type_, ...) --TODO: get rid of
    local vals = table.pack(...)
    for i=1,vals.n do
        result = (type_=="integer" and math.isInt(vals[i])) or type(vals[i])==type_
        assertEx(result, "%s must be a %s, got %s.", self.typeName, type_, type(vals[i]))
    end
end

function ASSBase:checkPositive(...)
    self:checkType("number", ...)
    local vals = table.pack(...)
    for i=1,vals.n do
        assertEx(vals[i] >= 0, "%s tagProps do not permit numbers < 0, got %d.", self.typeName, vals[i])
    end
end

function ASSBase:coerceNumber(num, default)
    num = tonumber(num)
    if not num then num=default or 0 end
    if self.__tag.positive then num=math.max(num,0) end
    if self.__tag.range then num=util.clamp(num,self.__tag.range[1], self.__tag.range[2]) end
    return num
end

function ASSBase:coerce(value, type_)
    assertEx(type(value)~="table", "can't cast a table to a %s.", tostring(type_))
    local tagProps = self.__tag or self.__defProps
    if type(value) == type_ then
        return value
    elseif type_ == "number" then
        if type(value)=="boolean" then return value and 1 or 0
        else
            cval = tonumber(value, tagProps.base or 10)
            assertEx(cval, "failed coercing value '%s' of type %s to a number on creation of %s object.",
                     tostring(value), type(value), self.typeName)
        return cval*(tagProps.scale or 1) end
    elseif type_ == "string" then
        return tostring(value)
    elseif type_ == "boolean" then
        return value~=0 and value~="0" and value~=false
    elseif type_ == "table" then
        return {value}
    end
end

function ASSBase:getArgs(args, defaults, coerce, extraValidClasses)
    -- TODO: make getArgs automatically create objects
    assertEx(type(args)=="table", "first argument to getArgs must be a table of arguments, got a %s.", type(args))
    local propTypes, propNames = self.__meta__.types, self.__meta__.order
    if not args then args={}
    -- process "raw" property that holds all tag parameters when parsed from a string
    elseif type(args.raw)=="table" then args=args.raw
    elseif args.raw then args={args.raw}
    -- check if first and only arg is a compatible ASSClass and dump into args
    elseif #args == 1 and type(args[1]) == "table" and args[1].instanceOf then
        local selfClasses = extraValidClasses and table.merge(self.compatible, extraValidClasses) or self.compatible
        local _, clsMatchCnt = table.intersect(selfClasses, args[1].compatible)

        if clsMatchCnt>0 then
            if args.deepCopy then
                args = {args[1]:get()}
            else
                -- This is a fast path for compatible objects
                -- TODO: check for issues caused by this change
                local obj = args[1]
                for i=1,#self.__meta__.order do
                    args[i] = obj[self.__meta__.order[i]]
                end
                return unpack(args)
            end
        else assertEx(type(propTypes[1]) == "table" and propTypes[1].instanceOf,
                      "object of class %s does not accept instances of class %s as argument.",
                      self.typeName, args[1].typeName
             )
        end
    end

    -- TODO: check if we can get rid of either the index into the default table or the output table
    local defIdx, j, outArgs, o = 1, 1, {}, 1
    for i=1,#propNames do
        if ASS.instanceOf(propTypes[i]) then
            local argSlice, a, rawArgCnt, propRawArgCnt, defSlice = {}, 1, 0, propTypes[i].__meta__.rawArgCnt
            while rawArgCnt<propRawArgCnt do
                argSlice[a], a = args[j], a+1
                rawArgCnt = rawArgCnt + (type(args[j])=="table" and args[j].class and args[j].__meta__.rawArgCnt or 1)
                j=j+1
            end

            if type(defaults) == "table" then
                defSlice = table.sliceArray(defaults, defIdx, defIdx+propRawArgCnt-1)
                defIdx = defIdx + propRawArgCnt
            end

            outArgs, o = table.joinInto(outArgs, {propTypes[i]:getArgs(argSlice, defSlice or defaults, coerce)})
        else
            if args[j]==nil then -- write defaults
                outArgs[o] = type(defaults)=="table" and defaults[defIdx] or defaults
            elseif type(args[j])=="table" and args[j].class then
                assertEx(args[j].__meta__.rawArgCnt==1, "type mismatch in argument #%d (%s). Expected a %s or a compatible object, but got a %s.",
                         i, propNames[i], propTypes[i], args[j].typeName)
                outArgs[o] = args[j]:get()
            elseif coerce and type(args[j])~=propTypes[i] then
                outArgs[o] = self:coerce(args[j], propTypes[i])
            else outArgs[o] = args[j] end
            j, defIdx = j+1, defIdx+1
        end
        o=o+1
    end
    return unpack(outArgs)
end

function ASSBase:copy()
    local newObj, meta = {}, getmetatable(self)
    setmetatable(newObj, meta)
    for key,val in pairs(self) do
        if key=="__tag" or not meta or (meta and table.find(self.__meta__.order,key)) then   -- only deep copy registered members of the object
            if ASS.instanceOf(val) then
                newObj[key] = val:copy()
            elseif type(val)=="table" then
                newObj[key]=ASSBase.copy(val)
            else newObj[key]=val end
        else newObj[key]=val end
    end
    return newObj
end

function ASSBase:typeCheck(...)
    local valTypes, valNames, j, args = self.__meta__.types, self.__meta__.order, 1, {...}
    for i=1,#valNames do
        if ASS.instanceOf(valTypes[i]) then
            if ASS.instanceOf(args[j]) then   -- argument and expected type are both ASSObjects, defer type checking to object
                self[valNames[i]]:typeCheck(args[j])
            else  -- collect expected number of arguments for target ASSObject
                local subCnt = #valTypes[i].__meta__.order
                valTypes[i]:typeCheck(unpack(table.sliceArray(args,j,j+subCnt-1)))
                j=j+subCnt-1
            end
        else
            assertEx(type(args[j])==valTypes[i] or args[j]==nil or valTypes[i]=="nil",
                   "bad type for argument #%d (%s). Expected %s, got %s.", i, valNames[i], valTypes[i], type(args[j]))
        end
        j=j+1
    end
    return unpack(args)
end

function ASSBase:get()
    local vals, names, valCnt = {}, self.__meta__.order, 1
    for i=1,#names do
        if ASS.instanceOf(self[names[i]]) then
            for j,subVal in pairs({self[names[i]]:get()}) do
                vals[valCnt], valCnt = subVal, valCnt+1
            end
        else
            vals[valCnt], valCnt = self[names[i]], valCnt+1
        end
    end
    return unpack(vals)
end

--- TODO: implement working alternative
--[[
function ASSBase:remove(returnCopy)
    local copy = returnCopy and ASSBase:copy() or true
    self = nil
    return copy
end
]]--


--------------------- Container Classes ---------------------

ASSLineContents = createASSClass("ASSLineContents", ASSBase, {"sections"}, {"table"})
function ASSLineContents:new(line,sections)
    sections = self:getArgs({sections})
    assertEx(line and line.__class==Line, "argument 1 to %s() must be a Line or %s object, got %s.",
             self.typeName, self.typeName, type(line))
    if not sections then
        sections = {}
        local i, j, drawingState, ovrStart, ovrEnd = 1, 1, ASS:createTag("drawing",0)
        while i<=#line.text do
            ovrStart, ovrEnd = line.text:find("{.-}",i)
            if ovrStart then
                if ovrStart>i then
                    local substr = line.text:sub(i,ovrStart-1)
                    sections[j], j = drawingState.value==0 and ASSLineTextSection(substr) or ASSLineDrawingSection{str=substr, scale=drawingState}, j+1
                end
                sections[j] = ASSLineTagSection(line.text:sub(ovrStart+1,ovrEnd-1))
                -- remove drawing tags from the tag sections so we don't have to keep state in sync with ASSLineDrawingSection
                local drawingTags = sections[j]:removeTags("drawing")
                if #sections[j].tags == 0 and #drawingTags>0 then
                    sections[j], j = nil, j-1
                end
                drawingState = drawingTags[#drawingTags] or drawingState
                i = ovrEnd +1
            else
                local substr = line.text:sub(i)
                sections[j] = drawingState.value==0 and ASSLineTextSection(substr) or ASSLineDrawingSection{str=substr, scale=drawingState}
                break
            end
            j=j+1
        end
    else sections = self:typeCheck(util.copy(sections)) end
    -- TODO: check if typeCheck works correctly with compatible classes and doesn't do useless busy work
    if line.parentCollection then
        self.sub, self.styles = line.parentCollection.sub, line.parentCollection.styles
        self.scriptInfo = line.parentCollection.meta
        ASS.cache.lastParentCollection = line.parentCollection
        ASS.cache.lastStyles, ASS.cache.lastSub = line.parentCollection.styles, self.sub
    else self.scriptInfo = self.sub and ASS:getScriptInfo(self.sub) end
    self.line, self.sections = line, sections
    self:updateRefs()
    return self
end

function ASSLineContents:updateRefs(prevCnt)
    if prevCnt~=#self.sections then
        for i=1,#self.sections do
            self.sections[i].prevSection = self.sections[i-1]
            self.sections[i].parent = self
            self.sections[i].index = i
        end
        return true
    else return false end
end

function ASSLineContents:getString(coerce, classes)
    local defDrawingState = ASS:createTag("drawing",0)
    local j, str, sections, prevDrawingState, secType, prevSecType = 1, {}, self.sections, defDrawingState

    for i=1,#sections do
        secType, lastSecType = ASS.instanceOf(sections[i], ASS.classes.lineSection, classes), secType
        if secType == ASSLineTextSection or secType == ASSLineDrawingSection then
            -- determine whether we need to enable or disable drawing mode and insert the appropriate tags
            local drawingState = secType==ASSLineDrawingSection and sections[i].scale or defDrawingState
            if drawingState ~= prevDrawingState then
                if prevSecType==ASSLineTagSection then
                    table.insert(str,j-1,drawingState:getTagString())
                    j=j+1
                else
                    str[j], str[j+1], str[j+2], j = "{", drawingState:getTagString(), "}", j+3
                end
                prevDrawingState = drawingState
            end
            str[j] = sections[i]:getString()

        elseif secType == ASSLineTagSection or secType==ASSLineCommentSection then
            str[j], str[j+1], str[j+2], j =  "{", sections[i]:getString(), "}", j+2

        else
            assertEx(coerce, "invalid %s section #%d. Expected {%s}, got a %s.",
                 self.typeName, i, table.concat(table.pluck(ASS.classes.lineSection, "typeName"), ", "),
                 type(sections[i])=="table" and sections[i].typeName or type(sections[i])
            )
        end
        prevSecType, j = secType, j+1
    end
    return table.concat(str)
end

function ASSLineContents:get(sectionClasses, start, end_, relative)
    local result, j = {}, 1
    self:callback(function(section,sections,i)
        result[j], j = section:copy(), j+1
    end, sectionClasses, start, end_, relative)
    return result
end

function ASSLineContents:callback(callback, sectionClasses, start, end_, relative, reverse)
    local prevCnt = #self.sections
    start = default(start,1)
    end_ = default(end_, start>=1 and math.max(prevCnt,1) or -1)
    reverse = relative and start<0 or reverse

    assertEx(math.isInt(start) and math.isInt(end_),
             "arguments 'start' and 'end' to callback() must be integers, got %s and %s.", type(start), type(end_))
    assertEx((start>0)==(end_>0) and start~=0 and end_~=0,
             "arguments 'start' and 'end' to callback() must be either both >0 or both <0, got %d and %d.", start, end_)
    assertEx(start <= end_, "condition 'start' <= 'end' not met, got %d <= %d", start, end_)

    local j, numRun, sects = 0, 0, self.sections
    if start<0 then
        start, end_ = relative and math.abs(end_) or prevCnt+start+1, relative and math.abs(start) or prevCnt+end_+1
    end

    for i=reverse and prevCnt or 1, reverse and 1 or prevCnt, reverse and -1 or 1 do
        if ASS.instanceOf(sects[i], ASS.classes.lineSection, sectionClasses) then
            j=j+1
            if (relative and j>=start and j<=end_) or (not relative and i>=start and i<=end_) then
                numRun = numRun+1
                local result = callback(sects[i],self.sections,i,j)
                if result==false then
                    sects[i]=nil
                elseif type(result)~="nil" and result~=true then
                    sects[i] = result
                    prevCnt=-1
                end
            end
        end
    end
    self.sections = table.reduce(self.sections)
    self:updateRefs(prevCnt)
    return numRun>0 and numRun or false
end

function ASSLineContents:insertSections(sections,index)
    index = index or #self.sections+1
    if type(sections)~="table" or sections.instanceOf then
        sections = {sections}
    end
    for i=1,#sections do
        assertEx(ASS.instanceOf(sections[i],ASS.classes.lineSection), "can only insert sections of type {%s}, got %s.",
                 table.concat(table.select(ASS.classes.lineSection, {"typeName"}), ", "), type(sections[i])
        )
        table.insert(self.sections, index+i-1, sections[i])
    end
    self:updateRefs()
    return sections
end

function ASSLineContents:removeSections(start, end_)
    local removed = {}
    if not start then
        self.sections, removed = {}, self.sections
    elseif type(start) == "number" then
        end_ = end_ or start
        removed = table.removeRange(self.sections, start, end_)
    elseif type(start) == "table" then
        local toRemove = start.instanceOf and {start=true} or table.arrayToSet(start)
        local j = 1
        for i=1, #self.sections do
            if toRemove[self.sections[i]] then
                local sect = self.sections[i]
                removed[i-j+1], self.sections[i] = sect, nil
                sect.parent, sect.index, sect.prevSection = nil, nil, nil
            elseif j~=i then
                self.sections[j], j = self.sections[i], j+1
            else j=i+1 end
        end
    else error("Error: invalid parameter #1. Expected a rangem, an ASSObject or a table of ASSObjects, got a " .. type(start)) end
    self:updateRefs()
    return removed
end

function ASSLineContents:modTags(tagNames, callback, start, end_, relative)
    start = default(start,1)
    end_ = default(end_, start<0 and -1 or math.max(self:getTagCount(),1))
    -- TODO: validation for start and end_
    local modCnt, reverse = 0, start<0

    self:callback(function(section)
        if (reverse and modCnt<-start) or (modCnt<end_) then
            local sectStart = reverse and start+modCnt or math.max(start-modCnt,1)
            local sectEnd = reverse and math.min(end_+modCnt,-1) or end_-modCnt
            local sectModCnt = section:modTags(tagNames, callback, relative and sectStart or nil, relative and sectEnd or nil, true)
            modCnt = modCnt + (sectModCnt or 0)
        end
    end, ASSLineTagSection, not relative and start or nil, not relative and end_ or nil, true, reverse)

    return modCnt>0 and modCnt or false
end

function ASSLineContents:getTags(tagNames, start, end_, relative)
    local tags, i = {}, 1

    self:modTags(tagNames, function(tag)
        tags[i], i = tag, i+1
    end, start, end_, relative)

    return tags
end

function ASSLineContents:replaceTags(tagList)  -- TODO: transform and reset support
    if type(tagList)=="table" then
        if tagList.class == ASSLineTagSection then
            tagList = ASSTagList(tagList)
        elseif tagList.class and tagList.class ~= ASSTagList then
            local tag = tagList
            tagList = ASSTagList(nil, self)
            tagList.tags[tag.__tag.name] = tag
        else tagList = ASSTagList(ASSLineTagSection(tagList)) end
    else
        assertEx(tagList==nil, "argument #1 must be a tag object, a table of tag objects, an %s or an ASSTagList; got a %s.",
                 ASSLineTagSection.typeName, ASSTagList.typeName, type(tagList))
        return
    end

    local firstIsTagSection = #self.sections>0 and self.sections[1].instanceOf[ASSLineTagSection]
    local globalSection = firstIsTagSection and self.sections[1] or ASSLineTagSection()
    local toInsert = ASSTagList(tagList)

    -- search for tags in line, replace them if found
    -- remove all matching global tags that are not in the first section
    self:callback(function(section,_,i)
        section:callback(function(tag)
            local props = tag.__tag
            if tagList.tags[props.name] then
                if props.global and i>1 then
                    return false
                else
                    toInsert.tags[props.name] = nil
                    return tagList.tags[props.name]:copy()
                end
            end
        end)
    end, ASSLineTagSection)

    -- insert the global tag section at the beginning of the line in case it doesn't exist
    if not firstIsTagSection and table.length(toInsert)>0 then
        self:insertSections(globalSection,1)
    end
    -- insert remaining tags (not replaced) into the first section
    globalSection:insertTags(toInsert)
end

function ASSLineContents:removeTags(tags, start, end_, relative)
    start = default(start,1)
    if relative then
        end_ = default(end_, start<0 and -1 or self:getTagCount())
    end
    -- TODO: validation for start and end_
    local removed, matchCnt, reverse  = {}, 0, start<0

    self:callback(function(section)
        if not relative then
            removed = table.join(removed,(section:removeTags(tags)))  -- exra parentheses because we only want the first return value
        elseif (reverse and matchCnt<-start) or (matchCnt<end_) then
            local sectStart = reverse and start+matchCnt or math.max(start-matchCnt,1)
            local sectEnd = reverse and math.min(end_+matchCnt,-1) or end_-matchCnt
            local sectRemoved, matched = section:removeTags(tags, sectStart, sectEnd, true)
            removed, matchCnt = table.join(removed,sectRemoved), matchCnt+matched
        end
    end, ASSLineTagSection, not relative and start or nil, not relative and end_ or nil, true, reverse)

    return removed
end

function ASSLineContents:insertTags(tags, index, sectionPosition, direct)
    assertEx(index==nil or math.isInt(index) and index~=0,
             "argument #2 (index) to insertTags() must be an integer != 0, got '%s' of type %s", tostring(index), type(index)
    )
    index = default(index, 1)

    if direct then
        local section = self.sections[index>0 and index or #self.sections-index+1]
        assertEx(ASS.instanceOf(section, ASSLineTagSection), "can't insert tag in section #%d of type %s.",
               index, section and section.typeName or "<no section>"
        )
        return section:insertTags(tags, sectionPosition)
    else
        local inserted
        local sectFound = self:callback(function(section)
            inserted = section:insertTags(tags, sectionPosition)
        end, ASSLineTagSection, index, index, true)
        if not sectFound and index==1 then
            inserted = self:insertSections(ASSLineTagSection(),1)[1]:insertTags(tags)
        end
        return inserted
    end
end

function ASSLineContents:insertDefaultTags(tagNames, index, sectionPosition, direct)
    local defaultTags = self:getDefaultTags():filterTags(tagNames)
    return self:insertTags(defaultTags, index, sectionPosition, direct)
end

function ASSLineContents:getEffectiveTags(index, includeDefault, includePrevious, copyTags)
    index, copyTags = default(index,1), default(copyTags, true)
    assertEx(math.isInt(index) and index~=0,
             "argument #1 (index) to getEffectiveTags() must be an integer != 0, got '%s' of type %s.",
             tostring(index), type(index)
    )
    if index<0 then index = index+#self.sections+1 end
    return self.sections[index] and self.sections[index]:getEffectiveTags(includeDefault,includePrevious,copyTags)
           or ASSTagList(nil, self)
end

function ASSLineContents:getTagCount()
    local cnt, sects = 0, self.sections
    for i=1,#sects do
        cnt = cnt + (sects[i].tags and #sects[i].tags or 0)
    end
    return cnt
end

function ASSLineContents:stripTags()
    self:callback(function(section,sections,i)
        return false
    end, ASSLineTagSection)
    return self
end

function ASSLineContents:stripText()
    self:callback(function(section,sections,i)
        return false
    end, ASSLineTextSection)
    return self
end

function ASSLineContents:stripComments()
    self:callback(function(section,sections,i)
        return false
    end, ASSLineCommentSection)
    return self
end

function ASSLineContents:stripDrawings()
    self:callback(function(section,sections,i)
        return false
    end, ASSLineDrawingSection)
    return self
end

function ASSLineContents:commit(line)
    line = line or self.line
    line.text, line.undoText = self:getString(), line.text
    line:createRaw()
    return line.text
end

function ASSLineContents:undoCommit(line)
    line = line or self.line
    if line.undoText then
        line.text, line.undoText = line.undoText
        line:createRaw()
        return true
    else return false end
end

function ASSLineContents:cleanTags(level, mergeSect, defaultToKeep, tagSortOrder)
    mergeSect, level = default(mergeSect,true), default(level,3)
    -- Merge consecutive sections
    if mergeSect then
        local lastTagSection, numMerged = -1, 0
        self:callback(function(section,sections,i)
            if i==lastTagSection+numMerged+1 then
                sections[lastTagSection].tags = table.join(sections[lastTagSection].tags, section.tags)
                numMerged = numMerged+1
                return false
            else
                lastTagSection, numMerged = i, 0
            end
        end, ASSLineTagSection)
    end

    -- 1: remove empty sections, 2: dedup tags locally, 3: dedup tags globally
    -- 4: remove tags matching style default and not changing state, end: remove empty sections
    local tagListPrev = ASSTagList(nil, self)

    if level>=3 then
        tagListDef = self:getDefaultTags()
        if not defaultToKeep or #defaultToKeep==1 and defaultToKeep[1]=="position" then
            -- speed up the default mode a little by using a precomputed tag name table
            tagListDef:filterTags(ASS.tagNames.noPos)
        else tagListDef:filterTags(defaultToKeep, nil, false, true) end
    end

    if level>=1 then
        self:callback(function(section,sections,i)
            if level<2 then return #section.tags>0 end
            local isLastSection = i==#sections

            local tagList = section:getEffectiveTags(false,false,false)
            if level>=3 then tagList:diff(tagListPrev) end
            if level>=4 then
                if i==#sections then tagList:filterTags(nil, {globalOrRectClip=true}) end
                tagList:diff(tagListDef:merge(tagListPrev,false,true),false,true)
            end
            if not isLastSection then tagListPrev:merge(tagList,false, false, false, true) end

            return not tagList:isEmpty() and ASSLineTagSection(tagList, false, tagSortOrder) or false
        end, ASSLineTagSection)
    end
    return self
end

function ASSLineContents:splitAtTags(cleanLevel, reposition, writeOrigin)
    cleanLevel = default(cleanLevel,3)
    local splitLines = {}
    self:callback(function(section,_,i,j)
        local splitLine = Line(self.line, self.line.parentCollection, {ASS={}})
        splitLine.ASS = ASSLineContents(splitLine, table.insert(self:get(ASSLineTagSection,0,i),section))
        splitLine.ASS:cleanTags(cleanLevel)
        splitLine.ASS:commit()
        splitLines[j] = splitLine
    end, ASSLineTextSection)
    if reposition then self:repositionSplitLines(splitLines, writeOrigin) end
    return splitLines
end

function ASSLineContents:splitAtIntervals(callback, cleanLevel, reposition, writeOrigin)
    cleanLevel = default(cleanLevel,3)
    if type(callback)=="number" then
        local step=callback
        callback = function(idx,len)
            return idx+step
        end
    else assertEx(type(callback)=="function", "argument #1 must be either a number or a callback function, got a %s.",
                 type(callback))
    end

    local len, idx, sectEndIdx, nextIdx, lastI = unicode.len(self:copy():stripTags():getString()), 1, 0, 0
    local splitLines, splitCnt = {}, 1

    self:callback(function(section,_,i)
        local sectStartIdx, text, off = sectEndIdx+1, section.value, sectEndIdx
        sectEndIdx = sectStartIdx + unicode.len(section.value)-1

        -- process unfinished line carried over from previous section
        if nextIdx > idx then
            -- carried over part may span over more than this entire section
            local skip = nextIdx>sectEndIdx+1
            idx = skip and sectEndIdx+1 or nextIdx
            local addTextSection = skip and section:copy() or ASSLineTextSection(text:sub(1,nextIdx-off-1))
            local addSections, lastContents = table.insert(self:get(ASSLineTagSection,lastI+1,i), addTextSection), splitLines[#splitLines].ASS
            lastContents:insertSections(addSections)
        end

        while idx <= sectEndIdx do
            nextIdx = math.ceil(callback(idx,len))
            assertEx(nextIdx>idx, "index returned by callback function must increase with every iteration, got %d<=%d.",
                     nextIdx, idx)
            -- create a new line
            local splitLine = Line(self.line, self.line.parentCollection)
            splitLine.ASS = ASSLineContents(splitLine, self:get(ASSLineTagSection,1,i))
            splitLine.ASS:insertSections(ASSLineTextSection(unicode.sub(text,idx-off,nextIdx-off-1)))
            splitLines[splitCnt], splitCnt = splitLine, splitCnt+1
            -- check if this section is long enough to fill the new line
            idx = sectEndIdx>=nextIdx-1 and nextIdx or sectEndIdx+1
        end
        lastI = i
    end, ASSLineTextSection)

    for i=1,#splitLines do
        splitLines[i].ASS:cleanTags(cleanLevel)
        splitLines[i].ASS:commit()
    end

    if reposition then self:repositionSplitLines(splitLines, writeOrigin) end
    return splitLines
end

function ASSLineContents:repositionSplitLines(splitLines, writeOrigin)
    writeOrigin = default(writeOrigin,true)
    local lineWidth = self:getTextExtents()
    local getAlignOffset = {
        [0] = function(wSec,wLine) return wSec-wLine end,    -- right
        [1] = function() return 0 end,                       -- left
        [2] = function(wSec,wLine) return wSec/2-wLine/2 end -- center
    }
    local xOff = 0
    local origin = writeOrigin and self:getEffectiveTags(-1,true,true,false).tags["origin"]


    for i=1,#splitLines do
        local data = splitLines[i].ASS
        -- get tag state at last line section, if you use more than one \pos, \org or \an in a single line,
        -- you deserve things breaking around you
        local effTags = data:getEffectiveTags(-1,true,true,false)
        local sectWidth = data:getTextExtents()

        -- kill all old position tags because we only ever need one
        data:removeTags("position")
        -- calculate new position
        local alignOffset = getAlignOffset[effTags.tags["align"]:get()%3](sectWidth,lineWidth)
        local pos = effTags.tags["position"]:copy()
        pos:add(alignOffset+xOff,0)
        -- write new position tag to first tag section
        data:insertTags(pos,1,1)

        -- if desired, write a new origin to the line if the style or the override tags contain any angle
        if writeOrigin and (#data:getTags({"angle","angle_x","angle_y"})>0 or effTags.tags["angle"]:get()~=0) then
            data:removeTags("origin")
            data:insertTags(origin:copy(),1,1)
        end

        xOff = xOff + sectWidth
        data:commit()
    end
    return splitLines
end

function ASSLineContents:getStyleRef(style)
    if ASS.instanceOf(style, ASSString) then
        style = style:get()
    end
    if style==nil or style=="" then
        style = self.line.styleRef
    elseif type(style)=="string" then
        style = self.line.parentCollection.styles[style] or style
        assertEx(type(style)=="table", "couldn't find style with name '%s'.", style)
    else assertEx(type(style)=="table" and style.class=="style",
                "invalid argument #1 (style): expected a style name or a styleRef, got a %s.", type(style))
    end
    return style
end

function ASSLineContents:getPosition(style, align, forceDefault)
    self.line:extraMetrics()
    local effTags = not (forceDefault and align) and self:getEffectiveTags(-1,false,true,false).tags
    style = self:getStyleRef(style)
    align = align or effTags.align or style.align

    if ASS.instanceOf(align,ASSAlign) then
        align = align:get()
    else assertEx(type(align)=="number", "argument #1 (align) must be of type number or %s, got a %s.",
         ASSAlign.typeName, ASS.instanceOf(align) or type(align))
    end

    if not forceDefault and effTags.position then
        return effTags.position
    end

    local scriptInfo = self.scriptInfo or ASS:getScriptInfo(self.sub)
    -- blatantly copied from torque's Line.moon
    vMargin = self.line.margin_t == 0 and style.margin_t or self.line.margin_t
    lMargin = self.line.margin_l == 0 and style.margin_l or self.line.margin_l
    rMargin = self.line.margin_r == 0 and style.margin_r or self.line.margin_r

    return ASS:createTag("position", self.line.defaultXPosition[align%3+1](scriptInfo.PlayResX, lMargin, rMargin),
                                     self.line.defaultYPosition[math.ceil(align/3)](scriptInfo.PlayResY, vMargin)
    ), ASS:createTag("align", align)
end

-- TODO: make all caches members of ASSFoundation
local styleDefaultCache = {}
function ASSLineContents:getDefaultTags(style, copyTags, useOvrAlign)
    copyTags, useOvrAlign = default(copyTags,true), default(useOvrAlign, true)
    local line = self.line
    style = self:getStyleRef(style)

    -- alignment override tag may affect the default position so we'll have to retrieve it
    local position, align = self:getPosition(style, not useOvrAlign and style.align, true)
    local raw = (useOvrAlign and style.align~=align.value) and style.raw.."_"..align.value or style.raw

    if styleDefaultCache[raw] then
        -- always return at least a fresh ASSTagList object to prevent the cached one from being overwritten
        return copyTags and styleDefaultCache[raw]:copy() or ASSTagList(styleDefaultCache[raw])
    end

    local function styleRef(tag)
        if tag:find("alpha") then
            return style[tag:gsub("alpha", "color")]:sub(3,4)
        elseif tag:find("color") then
            return style[tag]:sub(5,6), style[tag]:sub(7,8), style[tag]:sub(9,10)
        else return style[tag] end
    end

    local scriptInfo = self.scriptInfo or ASS:getScriptInfo(self.sub)
    local resX, resY = tonumber(scriptInfo.PlayResX), tonumber(scriptInfo.PlayResY)

    local tagList = ASSTagList(nil, self)
    tagList.tags = {
        scale_x = ASS:createTag("scale_x",styleRef("scale_x")),
        scale_y = ASS:createTag("scale_y", styleRef("scale_y")),
        align = ASS:createTag("align", styleRef("align")),
        angle = ASS:createTag("angle", styleRef("angle")),
        outline = ASS:createTag("outline", styleRef("outline")),
        outline_x = ASS:createTag("outline_x", styleRef("outline")),
        outline_y = ASS:createTag("outline_y", styleRef("outline")),
        shadow = ASS:createTag("shadow", styleRef("shadow")),
        shadow_x = ASS:createTag("shadow_x", styleRef("shadow")),
        shadow_y = ASS:createTag("shadow_y", styleRef("shadow")),
        alpha1 = ASS:createTag("alpha1", styleRef("alpha1")),
        alpha2 = ASS:createTag("alpha2", styleRef("alpha2")),
        alpha3 = ASS:createTag("alpha3", styleRef("alpha3")),
        alpha4 = ASS:createTag("alpha4", styleRef("alpha4")),
        color1 = ASS:createTag("color1", styleRef("color1")),
        color2 = ASS:createTag("color2", styleRef("color2")),
        color3 = ASS:createTag("color3", styleRef("color3")),
        color4 = ASS:createTag("color4", styleRef("color4")),
        clip_vect = ASS:createTag("clip_vect", {ASSDrawMove(0,0), ASSDrawLine(resX,0), ASSDrawLine(resX,resY), ASSDrawLine(0,resY), ASSDrawLine(0,0)}),
        iclip_vect = ASS:createTag("iclip_vect", {ASSDrawMove(0,0), ASSDrawLine(0,0), ASSDrawLine(0,0), ASSDrawLine(0,0), ASSDrawLine(0,0)}),
        clip_rect = ASS:createTag("clip_rect", 0, 0, resX, resY),
        iclip_rect = ASS:createTag("iclip_rect", 0, 0, 0, 0),
        bold = ASS:createTag("bold", styleRef("bold")),
        italic = ASS:createTag("italic", styleRef("italic")),
        underline = ASS:createTag("underline", styleRef("underline")),
        strikeout = ASS:createTag("strikeout", styleRef("strikeout")),
        spacing = ASS:createTag("spacing", styleRef("spacing")),
        fontsize = ASS:createTag("fontsize", styleRef("fontsize")),
        fontname = ASS:createTag("fontname", styleRef("fontname")),
        position = position,
        move_simple = ASS:createTag("move_simple", position, position),
        move = ASS:createTag("move", position, position),
        origin = ASS:createTag("origin", position),
    }
    for name,tag in pairs(ASS.tagMap) do
        if tag.default then tagList.tags[name] = tag.type{raw=tag.default, tagProps=tag.props} end
    end

    styleDefaultCache[style.raw] = tagList
    return copyTags and tagList:copy() or ASSTagList(tagList)
end

function ASSLineContents:getTextExtents(coerce)   -- TODO: account for linebreaks
    local width, other = 0, {0,0,0}
    self:callback(function(section)
        local extents = {section:getTextExtents(coerce)}
        width = width + table.remove(extents,1)
        table.process(other, extents, function(val1,val2)
            return math.max(val1,val2)
        end)
    end, ASSLineTextSection)
    return width, unpack(other)
end

function ASSLineContents:getLineBounds(noCommit)
    return ASSLineBounds(self, noCommit)
end

function ASSLineContents:getMetrics(includeLineBounds, includeTypeBounds, coerce)
    local metr = {ascent=0, descent=0, internal_leading=0, external_leading=0, height=0, width=0}
    local typeBounds = includeTypeBounds and {0,0,0,0}
    local textCnt = self:getSectionCount(ASSLineTextSection)

    self:callback(function(section, sections, i, j)
        local sectMetr = section:getMetrics(includeTypeBounds, coerce)
        -- combine type bounding boxes
        if includeTypeBounds then
            if j==1 then
                typeBounds[1], typeBounds[2] = sectMetr.typeBounds[1] or 0, sectMetr.typeBounds[2] or 0
            end
            typeBounds[2] = math.min(typeBounds[2],sectMetr.typeBounds[2] or 0)
            typeBounds[3] = typeBounds[1] + sectMetr.typeBounds.width
            typeBounds[4] = math.max(typeBounds[4],sectMetr.typeBounds[4] or 0)
        end

        -- add all section widths
        metr.width = metr.width + sectMetr.width
        -- get maximum encountered section values for all other metrics (does that make sense?)
        metr.ascent, metr.descent, metr.internal_leading, metr.external_leading, metr.height =
            math.max(sectMetr.ascent, metr.ascent), math.max(sectMetr.descent, metr.descent),
            math.max(sectMetr.internal_leading, metr.internal_leading), math.max(sectMetr.external_leading, metr.external_leading),
            math.max(sectMetr.height, metr.height)

    end, ASSLineTextSection)

    if includeTypeBounds then
        typeBounds.width, typeBounds.height = typeBounds[3]-typeBounds[1], typeBounds[4]-typeBounds[2]
        metr.typeBounds = typeBounds
    end

    if includeLineBounds then
        metr.lineBounds, metr.animated = self:getLineBounds()
    end

    return metr
end

function ASSLineContents:getSectionCount(classes)
    if classes then
        local cnt = 0
        self:callback(function(section, _, _, j)
            cnt = j
        end, classes, nil, nil, true)
        return cnt
    else
        local cnt = {}
        self:callback(function(section)
            local cls = table.keys(section.instanceOf)[1]
            cnt[cls] = cnt[cls] and cnt[cls]+1 or 1
        end)
        return cnt, #self.sections
    end
end

function ASSLineContents:isAnimated()
    local effTags, line, xres = self:getEffectiveTags(-1, false, true, false), self.line, aegisub.video_size()
    local frameCount = xres and aegisub.frame_from_ms(line.end_time) - aegisub.frame_from_ms(line.start_time)
    local t = effTags.tags

    if xres and frameCount<2 then return false end

    local karaTags = ASS.tagNames.karaoke
    for i=1,karaTags.n do
        if t[karaTags[i]] and t[karaTags[i]].value*t[karaTags[i]].__tag.scale < line.duration then
            -- this is broken right now due to incorrect handling of kara tags in getEffectiveTags
            return true
        end
    end

    if #effTags.transforms>0 or
    (t.move and not t.move.startPos:equal(t.move.endPos) and t.move.startTime<t.move.endTime) or
    (t.move_simple and not t.move_simple.startPos:equal(t.move_simple.endPos)) or
    (t.fade and (t.fade.startDuration>0 and not t.fade.startAlpha:equal(t.fade.midAlpha) or
                 t.fade.endDuration>0 and not t.fade.midAlpha:equal(t.fade.endAlpha))) or
    (t.fade_simple and (t.fade_simple.startDuration>0 and not t.fade_simple.startAlpha:equal(t.fade_simple.midAlpha) or
                        t.fade_simple.endDuration>0 and not t.fade_simple.midAlpha:equal(t.fade_simple.endAlpha))) then
        return true
    end

    return false
end

function ASSLineContents:reverse()
    local reversed, textCnt = {}, self:getSectionCount(ASSLineTextSection)
    self:callback(function(section,_,_,j)
        reversed[j*2-1] = ASSLineTagSection(section:getEffectiveTags(true,true))
        reversed[j*2] = section:reverse()
    end, ASSLineTextSection, nil, nil, nil, true)
    self.sections = reversed
    self:updateRefs()
    return self:cleanTags(4)
end

ASSLineBounds = createASSClass("ASSLineBounds", ASSBase, {1, 2, "w", "h", "fbf", "animated", "rawText"},
                              {"ASSPoint", "ASSPoint", "number", "number", "table", "boolean", "string"})
function ASSLineBounds:new(cnts, noCommit)
    -- TODO: throw error if no video is open
    assertEx(ASS.instanceOf(cnts, ASSLineContents), "argument #1 must be an object of type %s, got a %s.",
             ASSLineContents.typeName, ASS.instanceOf(cnts) or type(cnts)
    )
    if not noCommit then cnts:commit() end

    local assi, msg = ASS.cache.ASSInspector[cnts.line.parentCollection]
    if not assi then
        assi, msg = ASSInspector(cnts.sub)
        assertEx(assi, "ASSInspector Error: %s.", tostring(msg))
        ASS.cache.ASSInspector[cnts.line.parentCollection] = assi
    end

    self.animated = cnts:isAnimated()
    cnts.line.assi_exhaustive = self.animated

    local bounds, times = assi:getBounds{cnts.line}
    assertEx(bounds~=nil,"ASSInspector Error: %s.", tostring(times))

    if bounds[1]~=false or self.animated then
        local frame, x2Max, y2Max, x1Min, y1Min = aegisub.frame_from_ms, 0, 0
        self.fbf={off=frame(times[1]), n=#bounds}
        for i=1,self.fbf.n do
            if bounds[i] then
                local x1, y1, w, h = bounds[i].x, bounds[i].y, bounds[i].w, bounds[i].h
                local x2, y2 = x1+w, y1+h
                self.fbf[frame(times[i])] = {ASSPoint{x1,y1}, ASSPoint{x2,y2}, w=w, h=h, hash=bounds[i].hash}
                x1Min, y1Min = math.min(x1, x1Min or x1), math.min(y1, y1Min or y1)
                x2Max, y2Max = math.max(x2, x2Max), math.max(y2, y2Max)
            else self.fbf[frame(times[i])] = {w=0, h=0, hash=false} end
        end

        if x1Min then
           self[1], self[2], self.w, self.h = ASSPoint{x1Min,y1Min}, ASSPoint{x2Max, y2Max}, x2Max-x1Min, y2Max-y1Min
           self.firstHash = self.fbf[self.fbf.off].hash
        else self.w, self.h = 0, 0 end

    else self.w, self.h, self.fbf = 0, 0, {n=0} end

    self.rawText = cnts.line.text
    if not noCommit then cnts:undoCommit() end
    return self
end

function ASSLineBounds:equal(other)
    assertEx(ASS.instanceOf(other, ASSLineBounds), "argument #1 must be an object of type %s, got a %s.",
             ASSLineBounds.typeName, ASS.instanceOf(other) or type(other))
    if self.w + other.w == 0 then
        return true
    elseif self.w~=other.w or self.h~=other.h or self.animated~=other.animated or self.fbf.n~=other.fbf.n then
        return false
    end

    for i=0,self.fbf.n-1 do
        if self.fbf[self.fbf.off+i].hash ~= other.fbf[other.fbf.off+i].hash then
            return false
        end
    end

    return true
end

local ASSStringBase = createASSClass("ASSStringBase", ASSBase, {"value"}, {"string"})
function ASSStringBase:new(args)
    self.value = self:getArgs(args,"",true)
    self:readProps(args)
    return self
end

function ASSStringBase:append(str)
    return self:commonOp("append", function(val,str)
        return val..str
    end, "", str)
end

function ASSStringBase:prepend(str)
    return self:commonOp("prepend", function(val,str)
        return str..val
    end, "", str)
end

function ASSStringBase:replace(pattern, rep, plainMatch, useRegex)
    if plainMatch then
        useRegex, pattern = false, target:patternEscape()
    end
    self.value = useRegex and re.sub(self.value, pattern, rep) or self.value:gsub(pattern, rep)
    return self
end

function ASSStringBase:reverse()
    self.value = unicode.reverse(self.value)
    return self
end

ASSLineTextSection = createASSClass("ASSLineTextSection", ASSStringBase, {"value"}, {"string"})

function ASSLineTextSection:new(value)
    self.value = self:typeCheck(self:getArgs({value},"",true))
    return self
end

function ASSLineTextSection:getString(coerce)
    if coerce then return tostring(self.value)
    else return self:typeCheck(self.value) end
end


function ASSLineTextSection:getEffectiveTags(includeDefault, includePrevious, copyTags)
    includePrevious, copyTags = default(includePrevious, true), true
    -- previous and default tag lists
    local effTags
    if includeDefault then
        effTags = self.parent:getDefaultTags(nil, copyTags)
    end

    if includePrevious and self.prevSection then
        local prevTagList = self.prevSection:getEffectiveTags(false, true, copyTags)
        effTags = includeDefault and effTags:merge(prevTagList, false, false, true) or prevTagList
    end

    return effTags or ASSTagList(nil, self.parent)
end

function ASSLineTextSection:getStyleTable(name, coerce)
    return self:getEffectiveTags(false,true,false):getStyleTable(self.parent.line.styleRef, name, coerce)
end

function ASSLineTextSection:getTextExtents(coerce)
    return aegisub.text_extents(self:getStyleTable(nil,coerce),self.value)
end

function ASSLineTextSection:getMetrics(includeTypeBounds, coerce)
    assert(HAVE_YUTILS, YUtilsMissingMsg)
    local fontObj, tagList, shape = self:getYutilsFont()
    local metrics = table.merge(fontObj.metrics(),fontObj.text_extents(self.value))

    if includeTypeBounds then
        shape = fontObj.text_to_shape(self.value)
        metrics.typeBounds = {YUtils.shape.bounding(shape)}
        metrics.typeBounds.width = (metrics.typeBounds[3] or 0)-(metrics.typeBounds[1] or 0)
        metrics.typeBounds.height = (metrics.typeBounds[4] or 0)-(metrics.typeBounds[2] or 0)
    end

    return metrics, tagList, shape
end

function ASSLineTextSection:getShape(applyRotation, coerce)
    applyRotation = default(applyRotation, false)
    local metr, tagList, shape = self:getMetrics(true)
    local drawing, an = ASSDrawing{str=shape}, tagList.tags.align:getSet()
    -- fix position based on aligment
        drawing:sub(not an.left and (metr.width-metr.typeBounds.width)   / (an.centerH and 2 or 1) or 0,
                    not an.top  and (metr.height-metr.typeBounds.height) / (an.centerV and 2 or 1) or 0
        )

    -- rotate shape
    if applyRotation then
        local angle = tagList.tags.angle:getTagParams(coerce)
        drawing:rotate(angle)
    end
    return drawing
end

function ASSLineTextSection:convertToDrawing(applyRotation, coerce)
    local shape = self:getShape(applyRotation, coerce)
    self.value, self.contours, self.scale = nil, shape.contours, shape.scale
    setmetatable(self, ASSLineDrawingSection)
end

function ASSLineTextSection:getYutilsFont(coerce)
    assert(HAVE_YUTILS, YUtilsMissingMsg)
    local tagList = self:getEffectiveTags(true,true,false)
    local tags = tagList.tags
    return YUtils.decode.create_font(tags.fontname:getTagParams(coerce), tags.bold:getTagParams(coerce)>0,
                                     tags.italic:getTagParams(coerce)>0, tags.underline:getTagParams(coerce)>0, tags.strikeout:getTagParams(coerce)>0,
                                     tags.fontsize:getTagParams(coerce), tags.scale_x:getTagParams(coerce)/100, tags.scale_y:getTagParams(coerce)/100,
                                     tags.spacing:getTagParams(coerce)
    ), tagList
end

ASSLineCommentSection = createASSClass("ASSLineCommentSection", ASSLineTextSection, {"value"}, {"string"})

ASSLineTagSection = createASSClass("ASSLineTagSection", ASSBase, {"tags"}, {"table"})
ASSLineTagSection.tagMatch = re.compile("\\\\[^\\\\\\(]+(?:\\([^\\)]+\\)[^\\\\]*)?|[^\\\\]+")

function ASSLineTagSection:new(tags, transformableOnly, tagSortOrder)
    if ASS.instanceOf(tags,ASSTagList) then
        tagSortOrder = tagSortOrder or ASS.tagSortOrder
        -- TODO: check if it's a good idea to work with refs instead of copies
        local j=1
        self.tags = {}
        if tags.reset then
            self.tags[1], j = tags.reset, 2
        end

        for i=1,#tagSortOrder do
            local tag = tags.tags[tagSortOrder[i]]
            if tag and (not transformableOnly or tag.__tag.transformable or tag.instanceOf[ASSUnknown]) then
                self.tags[j], j = tag, j+1
            end
        end

        table.joinInto(self.tags, tags.transforms)
    elseif type(tags)=="string" or type(tags)=="table" and #tags==1 and type(tags[1])=="string" then
        if type(tags)=="table" then tags=tags[1] end
        self.tags = {}
        local tagMatch, i = self.tagMatch, 1
        for match in tagMatch:gfind(tags) do
            local tag, start, end_ = ASS:getTagFromString(match)
            if not transformableOnly or tag.__tag.transformable or tag.instanceOf[ASSUnknown] then
                self.tags[i], i = tag, i+1
                tag.parent = self
            end
            if end_ < #match then   -- comments inside tag sections are read into ASSUnknowns
                local afterStr = match:sub(end_+1)
                self.tags[i] = ASS:createTag(afterStr:sub(1,1)=="\\" and "unknown" or "junk", afterStr)
                self.tags[i].parent, i = self, i+1
            end
        end

        if #self.tags==0 and #tags>0 then    -- no tags found but string not empty -> must be a comment section
            return ASSLineCommentSection(tags)
        end
    elseif tags==nil then self.tags={}
    elseif ASS.instanceOf(tags, ASSLineTagSection) then
        -- does only shallow-copy, good idea?
        self.parent = tags.parent
        local j, otherTags = 1, tags.tags
        self.tags = {}
        for i=1,#otherTags do
            if transformableOnly and (otherTags[i].__tag.transformable or otherTags[i].instanceOf[ASSUnknown]) then
                self.tags[j] = otherTags[i]
                self.tags[j].parent, j = self, j+1
            end
        end
    elseif type(tags)=="table" then
        self.tags = {}
        local allTags = ASS.tagNames.all
        for i=1,#tags do
            local tag = tags[i]
            assertEx(allTags[tag.__tag.name or false], "supplied tag #d (a %s with name '%s') is not a supported tag.",
                     i, type(tag)=="table" and tags[i].typeName or type(tag), tag.__tag and tag.__tag.name)
            self.tags[i], tag.parent = tag, self
        end
    else self.tags = self:typeCheck(self:getArgs({tags})) end
    return self
end

function ASSLineTagSection:callback(callback, tagNames, start, end_, relative, reverse)
    local tagSet, prevCnt = {}, #self.tags
    start = default(start,1)
    end_ = default(end_, start>=1 and math.max(prevCnt,1) or -1)
    reverse = relative and start<0 or reverse

    assertEx(math.isInt(start) and math.isInt(end_), "arguments 'start' and 'end' must be integers, got %s and %s.",
             type(start), type(end_))
    assertEx((start>0)==(end_>0) and start~=0 and end_~=0,
             "arguments 'start' and 'end' must be either both >0 or both <0, got %d and %d.", start, end_)
    assertEx(start <= end_, "condition 'start' <= 'end' not met, got %d <= %d", start, end_)

    if type(tagNames)=="string" then tagNames={tagNames} end
    if tagNames then
        assertEx(type(tagNames)=="table", "argument #2 must be either a table of strings or a single string, got %s.", type(tagNames))
        for i=1,#tagNames do
            tagSet[tagNames[i]] = true
        end
    end

    local j, numRun, tags, tagsDeleted = 0, 0, self.tags, {}
    if start<0 then
        start, end_ = relative and math.abs(end_) or prevCnt+start+1, relative and math.abs(start) or prevCnt+end_+1
    end

    for i=reverse and prevCnt or 1, reverse and 1 or prevCnt, reverse and -1 or 1 do
        if not tagNames or tagSet[tags[i].__tag.name] then
            j=j+1
            if (relative and j>=start and j<=end_) or (not relative and i>=start and i<=end_) then
                local result = callback(tags[i],self.tags,i,j)
                numRun = numRun+1
                if result==false then
                    tags[i].deleted, tagsDeleted = true, {i}
                elseif type(result)~="nil" and result~=true then
                    tags[i] = result
                    tags[i].parent = self
                end
            end
        end
    end

    if #tagsDeleted>0 then
        table.removeFromArray(tags, unpack(tagsDeleted))
        for i=1,#tagsDeleted do
            tags[i].deleted = false
        end
    end
    return numRun>0 and numRun or false
end

function ASSLineTagSection:modTags(tagNames, callback, start, end_, relative)
    return self:callback(callback, tagNames, start, end_, relative)
end

function ASSLineTagSection:getTags(tagNames, start, end_, relative)
    local tags = {}
    self:callback(function(tag)
        tags[#tags+1] = tag
    end, tagNames, start, end_, relative)
    return tags
end

function ASSLineTagSection:remove()
    if not self.parent then return self end
    return self.parent:removeSections(self)
end

function ASSLineTagSection:removeTags(tags, start, end_, relative)
    if type(tags)=="number" and relative==nil then    -- called without tags parameter -> delete all tags in range
        tags, start, end_, relative = nil, tags, start, end_
    end

    if #self.tags==0 then
        return {}, 0
    elseif not (tags or start or end_) then
        -- remove all tags if called without parameters
        removed, self.tags = self.tags, {}
        return removed, #removed
    end

    start, end_ = default(start,1), default(end_, start and start<0 and -1 or #self.tags)
    -- wrap single tags and tag objects
    if tags~=nil and (type(tags)~="table" or ASS.instanceOf(tags)) then
        tags = {tags}
    end

    local tagNames, tagObjects, removed, reverse = {}, {}, {}, start<0
    -- build sets
    if tags and #tags>0 then
        for i=1,#tags do
            if ASS.instanceOf(tags[i]) then
                tagObjects[tags[i]] = true
            elseif type(tags[i]=="string") then
                tagNames[ASS:mapTag(tags[i]).props.name] = true
            else error(string.format("Error: argument %d to removeTags() must be either a tag name or a tag object, got a %s.", i, type(tags[i]))) end
        end
    end

    if reverse and relative then
        start, end_ = math.abs(end_), math.abs(start)
    end
    -- remove matching tags
    local matched = 0
    self:callback(function(tag)
        if tagNames[tag.__tag.name] or tagObjects[tag] or not tags then
            matched = matched + 1
            if not relative or (matched>=start and matched<=end_) then
                removed[#removed+1], tag.parent = tag, nil
                return false
            end
        end
    end, nil, not relative and start or nil, not relative and end_ or nil, false, reverse)

    return removed, matched
end

function ASSLineTagSection:insertTags(tags, index)
    local prevCnt, inserted = #self.tags, {}
    index = default(index,math.max(prevCnt,1))
    assertEx(math.isInt(index) and index~=0,
           "argument #2 (index) must be an integer != 0, got '%s' of type %s.", tostring(index), type(index))

    if type(tags)=="table" then
        if tags.instanceOf[ASSLineTagSection] then
            tags = tags.tags
        elseif tags.instanceOf[ASSTagList] then
            tags = ASSLineTagSection(tags).tags
        elseif tags.instanceOf then tags = {tags} end
    else error("Error: argument 1 (tags) must be one of the following: a tag object, a table of tag objects, an ASSLineTagSection or an ASSTagList; got a "
               .. type(tags) .. ".")
    end

    for i=1,#tags do
        local cls = tags[i].class
        if not cls then
            error(string.format("Error: argument %d to insertTags() must be a tag object, got a %s", i, type(tags[i])))
        end

        local tagData = ASS.tagMap[tags[i].__tag.name]
        if not tagData then
            error(string.format("Error: can't insert tag #%d of type %s: no tag with name '%s'.", i, tags[i].typeName, tags[i].__tag.name))
        elseif cls ~= tagData.type then
            error(string.format("Error: can't insert tag #%d with name '%s': expected type was %s, got %s.",
                                i, tags[i].__tag.name, tagData.type.typeName, tags[i].typeName)
            )
        end

        local insertIdx = index<0 and prevCnt+index+i or index+i-1
        table.insert(self.tags, insertIdx, tags[i])
        tags[i].parent, tags[i].deleted = self, false
        inserted[i] = self.tags[insertIdx]
    end
    return #inserted>1 and inserted or inserted[1]
end

function ASSLineTagSection:insertDefaultTags(tagNames, index)
    local defaultTags = self.parent:getDefaultTags():getTags(tagNames)
    return self:insertTags(defaultTags, index)
end

function ASSLineTagSection:getString(coerce)
    local tagStrings = {}
    self:callback(function(tag, _, i)
        tagStrings[i] = tag:getTagString(coerce)
    end)
    return table.concat(tagStrings)
end

function ASSLineTagSection:getEffectiveTags(includeDefault, includePrevious, copyTags)   -- TODO: properly handle transforms, include forward sections for global tags
    includePrevious, copyTags = default(includePrevious, true), true
    -- previous and default tag lists
    local effTags
    if includeDefault then
        effTags = self.parent:getDefaultTags(nil, copyTags)
    end
    if includePrevious and self.prevSection then
        local prevTagList = self.prevSection:getEffectiveTags(false, true, copyTags)
        effTags = includeDefault and effTags:merge(prevTagList, false, false, true) or prevTagList
        includeDefault = false
    end
    -- tag list of this section
    local tagList = copyTags and ASSTagList(self):copy() or ASSTagList(self)
    return effTags and effTags:merge(tagList, false, nil, includeDefault) or tagList
end

ASSLineTagSection.getStyleTable = ASSLineTextSection.getStyleTable


ASSTagList = createASSClass("ASSTagList", ASSBase, {"tags", "transforms" ,"reset", "startTime", "endTime", "accel"},
                            {"table", "table", ASSString, ASSTime, ASSTime, ASSNumber})

function ASSTagList:new(tags, contentRef)
    if ASS.instanceOf(tags, ASSLineTagSection) then
        self.tags, self.transforms, self.contentRef = {}, {}, tags.parent
        local trIdx, transforms, ovrTransTags, transTags = 1, {}, {}
        local seenVectClip, childAlphaNames = false, ASS.tagNames.childAlpha

        tags:callback(function(tag)
            local props = tag.__tag

            -- Discard all previous non-global tags when a reset is encountered (including all transformed tags)
            -- Vectorial clips are not "global" but can't be reset
            if props.name == "reset" then
                self.tags, self.reset = self:getGlobal(true), tag

                for i=1,#transforms do
                    local keep = false
                    transforms[i].tags:callback(function(tag)
                        if tag.instanceOf[ASSClipRect] then
                            keep = true
                        else return false end
                    end)
                    if not keep then transforms[i] = nil end
                end

            -- Transforms are stored in a separate table because there can be more than one.
            -- When the list is converted back into an ASSTagSection, the transforms are written to its end,
            -- so we have to make sure transformed tags are not overridden afterwards:
            -- If a transform is encountered any entries in the overridden transforms list
            -- are marked as limited to all previous transforms in the transforms list.
            elseif tag.instanceOf[ASSTransform] then
                transforms[trIdx] = ASSTransform{tag, transformableOnly=true}   -- we need a shallow copy of the transform to filter
                transTags, trIdx = transforms[trIdx].tags.tags, trIdx+1
                for j=1,#transTags do
                    if ovrTransTags[transTags[j].__tag.name] then
                        ovrTransTags[transTags[j].__tag.name] = trIdx-1
                    end
                end

            -- Discard all except the first instance of global tags.
            -- This expects all global tags to be non-transformable which is true for ASSv4+
            -- Since there can be only one vectorial clip or iclip at a time, only keep the first one
            elseif not (self.tags[props.name] and props.global)
            and not (seenVectClip and tag.instanceOf[ASSClipVect]) then
                self.tags[props.name] = tag
                if tag.__tag.transformable then
                    ovrTransTags[tag.__tag.name] = -1
                elseif tag.instanceOf[ASSClipVect]  then
                    seenVectClip = true
                end
                if tag.__tag.masterAlpha then
                    for i=1,#childAlphaNames do
                        self.tags[childAlphaNames[i]] = nil
                    end
                end
            end
        end)

        -- filter tags by overridden transform list, keep transforms that have still tags left at the end
        local t=1
        for i=1,trIdx-1 do
            if transforms[i] then
                local transTagCnt = 0
                transforms[i].tags:callback(function(tag)
                    local ovrEnd = ovrTransTags[tag.__tag.name] or 0
                    -- drop all overridden transforms
                    if ovrEnd==-1 or ovrEnd>i then
                        return false
                    else transTagCnt = transTagCnt+1 end
                end)
                -- write final transforms table
                if transTagCnt>0 then
                    self.transforms[t], t = transforms[i], t+1
                end
            end
        end

    elseif ASS.instanceOf(tags, ASSTagList) then
        self.tags, self.reset, self.transforms = util.copy(tags.tags), tags.reset, util.copy(tags.transforms)
        self.contentRef = tags.contentRef
    elseif tags==nil then
        self.tags, self.transforms = {}, {}
    else error(string.format("Error: an %s can only be constructed from an %s or %s; got a %s.",
                              ASSTagList.typeName, ASSLineTagSection.typeName, ASSTagList.typeName,
                              ASS.instanceOf(tags) and tags.typeName or type(tags))
         )
    end
    self.contentRef = contentRef or self.contentRef
    return self
end

function ASSTagList:get()
    local flatTagList = {}
    for name,tag in pairs(self.tags) do
        flatTagList[name] = tag:get()
    end
    return flatTagList
end

function ASSTagList:isTagTransformed(tagName)
    local set = {}
    for i=1,#self.transforms do
        for j=1,#self.transforms[i].tags.tags do
            set[self.transforms[i].tags.tags[j].__tag.name] = true
        end
    end
    return tagName and set[tagName] or set
end

function ASSTagList:merge(tagLists, copyTags, returnOnly, overrideGlobalTags, expandResets)
    copyTags = default(copyTags, true)
    if ASS.instanceOf(tagLists, ASSTagList) then
        tagLists = {tagLists}
    end

    local merged, ovrTransTags, resetIdx = ASSTagList(self), {}, 0
    local seenTransform, seenVectClip = #self.transforms>0, self.clip_vect or self.iclip_vect
    local childAlphaNames = ASS.tagNames.childAlpha

    if expandResets and self.reset then
        local expReset = merged.contentRef:getDefaultTags(merged.reset)
        merged.tags = merged:getDefaultTags(merged.reset):merge(merged.tags, false)
    end

    for i=1,#tagLists do
        assertEx(ASS.instanceOf(tagLists[i],ASSTagList),
                 "can only merge %s objects, got a %s for argument #%d.", ASSTagList.typeName, type(tagLists[i]), i)

        if tagLists[i].reset then
            if expandResets then
                local expReset = tagLists[i].contentRef:getDefaultTags(tagLists[i].reset)
                merged.tags = overrideGlobalTags and expReset or expReset:merge(merged:getGlobal(true),false)
            else
                -- discard all previous non-global tags when a reset is encountered
                merged.tags, merged.reset = merged:getGlobal(true), tagLists[i].reset
            end

            resetIdx = i
        end

        seenTransform = seenTransform or #tagLists[i].transforms>0

        for name,tag in pairs(tagLists[i].tags) do
            -- discard all except the first instance of global tags
            -- also discard all vectorial clips if one was already seen
            if overrideGlobalTags or not (merged.tags[name] and tag.__tag.global)
            and not (seenVectClip and tag.instanceOf[ASSClipVect]) then
                -- when overriding tags, make sure vect. iclips also overwrite vect. clips and vice versa
                if overrideGlobalTags then
                    merged.tags.clip_vect, merged.tags.iclip_vect = nil, nil
                end
                merged.tags[name] = tag
                -- mark transformable tags in previous transform lists as overridden
                if seenTransform and tag.__tag.transformable then
                    ovrTransTags[tag.__tag.name] = i
                end
                if tag.__tag.masterAlpha then
                    for i=1,#childAlphaNames do
                        self.tags[childAlphaNames[i]] = nil
                    end
                end
            end
        end
    end

    merged.transforms = {}
    if seenTransform then
        local t=1
        for i=0,#tagLists do
            local transforms = i==0 and self.transforms or tagLists[i].transforms
            for j=1,#transforms do
                local transform = i==0 and transforms[j] or ASSTransform{transforms[j]}
                local transTagCnt = 0

                transform.tags:callback(function(tag)
                    local ovrEnd = ovrTransTags[tag.__tag.name] or 0
                    -- remove transforms overwritten by resets or the override table
                    if resetIdx>i and not tag.instanceOf[ASSClipRect] or ovrEnd>i then
                        return false
                    else transTagCnt = transTagCnt+1 end
                end)

                -- fill final transforms table
                if transTagCnt > 0 then
                    merged.transforms[t], t = transform, t+1
                end
            end
        end
    end

    if copyTags then merged = merged:copy() end
    if not returnOnly then
        self.tags, self.reset, self.transforms = merged.tags, merged.reset, merged.transforms
        return self
    else return merged end
end

function ASSTagList:diff(other, returnOnly, ignoreGlobalState) -- returnOnly note: only provided because copying the tag list before diffing may be much slower
    assertEx(ASS.instanceOf(other,ASSTagList), "can only diff %s objects, got a %s.", ASSTagList.typeName, type(other))

    local diff, ownReset = ASSTagList(nil, self.contentRef), self.reset

    if #other.tags == 0 and self.reset and (
        other.reset and self.reset.value == other.reset.value
        or not other.reset and (self.reset.value == "" or self.reset.value == other.contentRef:getStyleRef().name)
    ) then
        ownReset, self.reset = nil, returnOnly and self.reset or nil
    end

    local defaults = ownReset and self.contentRef:getDefaultTags(ownReset)
    local otherReset = other.reset and other.contentRef:getDefaultTags(other.reset)
    local otherTransSet = other:isTagTransformed()

    for name,tag in pairs(self.tags) do
        local global = tag.__tag.global and not ignoreGlobalState

        -- if this tag list contains a reset, we need to compare its local tags to the default values set by the reset
        -- instead of to the values of the other tag list
        local ref = (ownReset and not global) and defaults or other

        -- Since global tags can't be overwritten, only treat global tags that are not
        -- present in the other tag list as different.
        -- There can be only vector (i)clip at the time, so treat any we encounter in this list only as different
        -- when there are neither in the other list.
        if global and not other.tags[name]
                  and not (tag.instanceOf[ASSClipVect] and (other.tags.clip_vect or other.tags.iclip_vect))
        -- all local tags transformed in the previous section will change state (no matter the tag values) when used in this section,
        -- unless this section begins with a reset, in which case only rectangular clips are kept
        or not (global or ownReset and not tag.instanceOf[ASSClipRect]) and otherTransSet[name]
        -- check local tags for equality in reference list
        or not (global or tag:equal(ref.tags[name]) or otherReset and tag:equal(otherReset.tags[name])) then
            if returnOnly then diff.tags[name] = tag end

        elseif not returnOnly then
            self.tags[name] = nil
        end
    end
    diff.reset = ownReset
    -- transforms can't be deduplicated so all of them will be kept in the diff
    diff.transforms = self.transforms
    return returnOnly and diff or self
end

function ASSTagList:getStyleTable(styleRef, name, coerce)
    assertEx(type(styleRef)=="table" and styleRef.class=="style",
             "argument #1 must be a style table, got a %s.", type(styleRef))
    local function color(num)
        local a, c = "alpha"..tostring(num), "color"..tostring(num)
        local alpha, color = tag(a), {tag(c)}
        local str = (alpha and string.format("&H%02X", alpha) or styleRef[c]:sub(1,4)) ..
                    (#color==3 and string.format("%02X%02X%02X&", unpack(color)) or styleRef[c]:sub(5))
        return str
    end
    function tag(name,bool)
        if self.tags[name] then
            local vals = {self.tags[name]:getTagParams(coerce)}
            if bool then
                return vals[1]>0
            else return unpack(vals) end
        end
    end

    local sTbl = {
        name = name or styleRef.name,
        id = util.uuid(),

        align=tag("align"), angle=tag("angle"), bold=tag("bold",true),
        color1=color(1), color2=color(2), color3=color(3), color4=color(4),
        encoding=tag("encoding"), fontname=tag("fontname"), fontsize=tag("fontsize"),
        italic=tag("italic",true), outline=tag("outline"), underline=tag("underline",true),
        scale_x=tag("scale_x"), scale_y=tag("scale_y"), shadow=tag("shadow"),
        spacing=tag("spacing"), strikeout=tag("strikeout",true)
    }
    sTbl = table.merge(styleRef,sTbl)

    sTbl.raw = string.formatFancy("Style: %s,%s,%N,%s,%s,%s,%s,%B,%B,%B,%B,%N,%N,%N,%N,%d,%N,%N,%d,%d,%d,%d,%d",
               sTbl.name, sTbl.fontname, sTbl.fontsize, sTbl.color1, sTbl.color2, sTbl.color3, sTbl.color4,
               sTbl.bold, sTbl.italic, sTbl.underline, sTbl.strikeout, sTbl.scale_x, sTbl.scale_y,
               sTbl.spacing, sTbl.angle, sTbl.borderstyle, sTbl.outline, sTbl.shadow, sTbl.align,
               sTbl.margin_l, sTbl.margin_r, sTbl.margin_t, sTbl.encoding
    )
    return sTbl
end

function ASSTagList:filterTags(tagNames, tagProps, returnOnly, inverseNameMatch)
    if type(tagNames)=="string" then tagNames={tagNames} end
    assertEx(not tagNames or type(tagNames)=="table",
             "argument #1 must be either a single or a table of tag names, got a %s.", type(tagNames))

    local filtered = ASSTagList(nil, self.contentRef)
    local selected, transNames, retTrans = {}, ASS.tagNames[ASSTransform]
    local propCnt = tagProps and table.length(tagProps) or 0

    if not tagNames and not (tagProps or #tagProps==0) then
        return returnOnly and self:copy() or self
    elseif not tagNames then
        tagNames = ASS.tagNames.all
    elseif #tagNames==0 then
        return filtered
    elseif inverseNameMatch then
        tagNames = table.diff(tagNames, ASS.tagNames.all)
    end

    for i=1,#tagNames do
        local name, propMatch = tagNames[i], true
        local selfTag = name=="reset" and self.reset or self.tags[name]
        assertEx(type(name)=="string", "invalid tag name #%d '(%s)'. expected a string, got a %s",
                 i, tostring(name), type(name))

        if propCnt~=0 and selfTag then
            local _, propMatchCnt = table.intersect(tagProps, self.tags[name].__tag)
            propMatch = propMatchCnt == propCnt
        end

        if not (propMatch and selfTag) then
            -- do nothing
        elseif name == "reset" then
            filtered.reset = selfTag
        elseif transNames[name] then
            retTrans = true         -- TODO: filter transforms by type
        elseif self.tags[name] then
            filtered.tags[name] = selfTag
        end
    end

    if returnOnly then
        if retTransforms then filtered.transforms = util.copy(self.transforms) end
        return filtered
    end

    self.tags, self.reset, self.transforms = filtered.tags, filtered.reset, retTrans and self.transforms or {}
    return self
end

function ASSTagList:isEmpty()
    return table.length(self.tags)<1 and not self.reset and #self.transforms==0
end

function ASSTagList:getGlobal(includeRectClips)
    local global = {}
    for name,tag in pairs(self.tags) do
        global[name] = (includeRectClips and tag.__tag.globalOrRectClip or tag.__tag.global) and tag or nil
    end
    return global
end
--------------------- Override Tag Classes ---------------------

ASSTagBase = createASSClass("ASSTagBase", ASSBase)

function ASSTagBase:commonOp(method, callback, default, ...)
    local args = {self:getArgs({...}, default, false)}
    local j, valNames = 1, self.__meta__.order
    for i=1,#valNames do
        if ASS.instanceOf(self[valNames[i]]) then
            local subCnt = #self[valNames[i]].__meta__.order
            local subArgs = unpack(table.sliceArray(args,j,j+subCnt-1))
            self[valNames[i]][method](self[valNames[i]],subArgs)
            j=j+subCnt
        else
            self[valNames[i]]=callback(self[valNames[i]],args[j])
            j = self[valNames[i]], j+1
        end
    end
    return self
end

function ASSTagBase:add(...)
    return self:commonOp("add", function(a,b) return a+b end, 0, ...)
end

function ASSTagBase:sub(...)
    return self:commonOp("sub", function(a,b) return a-b end, 0, ...)
end

function ASSTagBase:mul(...)
    return self:commonOp("mul", function(a,b) return a*b end, 1, ...)
end

function ASSTagBase:div(...)
    return self:commonOp("div", function(a,b) return a/b end, 1, ...)
end

function ASSTagBase:pow(...)
    return self:commonOp("pow", function(a,b) return a^b end, 1, ...)
end

function ASSTagBase:mod(...)
    return self:commonOp("mod", function(a,b) return a%b end, 1, ...)
end

function ASSTagBase:set(...)
    return self:commonOp("set", function(a,b) return b end, nil, ...)
end

function ASSTagBase:modify(callback, ...)
    return self:set(callback(self:get(...)))
end

function ASSTagBase:readProps(args)
    if type(args[1])=="table" and args[1].instanceOf and args[1].instanceOf[self.class] then
        for k, v in pairs(args[1].__tag) do
            self.__tag[k] = v
        end
    elseif args.tagProps then
        for key, val in pairs(args.tagProps) do
            self.__tag[key] = val
        end
    end
end

function ASSTagBase:getTagString(coerce)
    return (self.disabled or self.deleted) and "" or ASS:formatTag(self, self:getTagParams(coerce))
end

function ASSTagBase:equal(ASSTag)  -- checks equalness only of the relevant properties
    local vals2
    if type(ASSTag)~="table" then
        vals2 = {ASSTag}
    elseif not ASSTag.instanceOf then
        vals2 = ASSTag
    elseif ASS.instanceOf(ASSTag)==ASS.instanceOf(self) and self.__tag.name==ASSTag.__tag.name then
        vals2 = {ASSTag:get()}
    else return false end

    local vals1 = {self:get()}
    if #vals1~=#vals2 then return false end

    for i=1,#vals1 do
        if type(vals1[i])=="table" and #table.intersectInto(vals1[i],vals2[i]) ~= #vals2[i] then
            return false
        elseif type(vals1[i])~="table" and vals1[i]~=vals2[i] then return false end
    end

    return true
end

ASSNumber = createASSClass("ASSNumber", ASSTagBase, {"value"}, {"number"}, {base=10, precision=3, scale=1})

function ASSNumber:new(args)
    self:readProps(args)
    self.value = self:getArgs(args,0,true)
    self:checkValue()
    if self.__tag.mod then self.value = self.value % self.__tag.mod end
    return self
end

function ASSNumber:checkValue()
    self:typeCheck(self.value)
    if self.__tag.range then
        math.inRange(self.value, self.__tag.range[1], self.__tag.range[2], self.typeName, self.integer)
    else
        if self.__tag.positive then assertEx(self.value>=0, "%s must be a positive number, got %d.", self.typeName, self.value) end
        if self.__tag.integer then math.isInt(self.value, self.typeName) end
    end
end

function ASSNumber:getTagParams(coerce, precision)
    precision = precision or self.__tag.precision
    local val = self.value
    if coerce then
        self:coerceNumber(val,0)
    else
        assertEx(precision <= self.__tag.precision, "output wih precision %d is not supported for %s (maximum: %d).",
                 precision, self.typeName, self.__tag.precision)
        self:checkValue()
    end
    if self.__tag.mod then val = val % self.__tag.mod end
    return math.round(val,self.__tag.precision)
end

function ASSNumber.cmp(a, mode, b)
    local modes = {
        ["<"] = function() return a<b end,
        [">"] = function() return a>b end,
        ["<="] = function() return a<=b end,
        [">="] = function() return a>=b end
    }

    local errStr = "operand %d must be a number or an object of (or based on) the %s class, got a %s."
    if type(a)=="table" and (a.instanceOf[ASSNumber] or a.baseClasses[ASSNumber]) then
        a = a:get()
    else assertEx(type(a)=="number", errStr, 1, ASSNumber.typeName, ASS.instanceOf(a) and a.typeName or type(a)) end

    if type(b)=="table" and (b.instanceOf[ASSNumber] or b.baseClasses[ASSNumber]) then
        b = b:get()
    else assertEx(type(b)=="number", errStr, 1, ASSNumber.typeName, ASS.instanceOf(b) and b.typeName or type(b)) end

    return modes[mode]()
end

function ASSNumber.__lt(a,b) return ASSNumber.cmp(a, "<", b) end
function ASSNumber.__le(a,b) return ASSNumber.cmp(a, "<=", b) end
function ASSNumber.__add(a,b) return type(a)=="table" and a:copy():add(b) or b:copy():add(a) end
function ASSNumber.__sub(a,b) return type(a)=="table" and a:copy():sub(b) or ASSNumber{a}:sub(b) end
function ASSNumber.__mul(a,b) return type(a)=="table" and a:copy():mul(b) or b:copy():mul(a) end
function ASSNumber.__div(a,b) return type(a)=="table" and a:copy():div(b) or ASSNumber{a}:div(b) end
function ASSNumber.__mod(a,b) return type(a)=="table" and a:copy():mod(b) or ASSNumber{a}:mod(b) end
function ASSNumber.__pow(a,b) return type(a)=="table" and a:copy():pow(b) or ASSNumber{a}:pow(b) end


ASSPoint = createASSClass("ASSPoint", ASSTagBase, {"x","y"}, {ASSNumber, ASSNumber})
function ASSPoint:new(args)
    local x, y = self:getArgs(args,0,true)
    self:readProps(args)
    self.x, self.y = ASSNumber{x}, ASSNumber{y}
    return self
end

function ASSPoint:getTagParams(coerce, precision)
    return self.x:getTagParams(coerce, precision), self.y:getTagParams(coerce, precision)
end

function ASSPoint:getAngle(ref, vectAngle)
    local rx, ry
    assertEx(type(ref)=="table", "argument #1 (ref) must be of type table, got a %s.", type(ref))
    if ref.instanceOf[ASSDrawBezier] then
        rx, ry = ref.p3:get()
    elseif not ref.instanceOf then
        rx, ry = ref[1], ref[2]
        assertEx(type(rx)=="number" and type(rx)=="number",
                 "table with reference coordinates must be of format {x,y}, got {%s,%s}.", tostring(rx), tostring(ry))
    elseif ref.compatible[ASSPoint] then
        rx, ry = ref:get()
    else error(string.format(
               "Error: argument #1 (ref) be an %s (or compatible), a drawing command or a coordinates table, got a %s.",
               ASSPoint.typeName, ref.typeName))
    end
    local sx, sy = self.x.value, self.y.value
    local cw = (sx*ry - sy*rx)<0
    local deg = math.deg(vectAngle and math.acos((sx*rx + sy*ry) / math.sqrt(sx^2 + sy^2) /
                                       math.sqrt(rx^2 + ry^2)) * (cw and 1 or -1)
                                    or -math.atan2(sy-ry, sx-rx))
    return ASS:createTag("angle", deg), cw
end

-- TODO: ASSPosition:move(ASSPoint) -> return \move tag

ASSTime = createASSClass("ASSTime", ASSNumber, {"value"}, {"number"}, {precision=0})
-- TODO: implement adding by framecount

function ASSTime:getTagParams(coerce, precision)
    precision = precision or 0
    local val = self.value
    if coerce then
        precision = math.min(precision,0)
        val = self:coerceNumber(0)
    else
        assertEx(precision <= 0, "%s doesn't support floating point precision.", self.typeName)
        self:checkType("number", self.value)
        if self.__tag.positive then self:checkPositive(self.value) end
    end
    val = val/self.__tag.scale
    return math.round(val,precision)
end

ASSDuration = createASSClass("ASSDuration", ASSTime, {"value"}, {"number"}, {positive=true})
ASSHex = createASSClass("ASSHex", ASSNumber, {"value"}, {"number"}, {range={0,255}, base=16, precision=0})

ASSColor = createASSClass("ASSColor", ASSTagBase, {"r","g","b"}, {ASSHex,ASSHex,ASSHex})
function ASSColor:new(args)
    local b,g,r = self:getArgs(args,nil,true)
    self:readProps(args)
    self.r, self.g, self.b = ASSHex{r}, ASSHex{g}, ASSHex{b}
    return self
end

function ASSColor:addHSV(h,s,v)
    local ho,so,vo = util.RGB_to_HSV(self.r:get(),self.g:get(),self.b:get())
    local r,g,b = util.HSV_to_RGB(ho+h,util.clamp(so+s,0,1),util.clamp(vo+v,0,1))
    return self:set(r,g,b)
end

function ASSColor:getTagParams(coerce)
    return self.b:getTagParams(coerce), self.g:getTagParams(coerce), self.r:getTagParams(coerce)
end

ASSFade = createASSClass("ASSFade", ASSTagBase,
    {"startDuration", "endDuration", "startTime", "endTime", "startAlpha", "midAlpha", "endAlpha"},
    {ASSDuration,ASSDuration,ASSTime,ASSTime,ASSHex,ASSHex,ASSHex}
)
function ASSFade:new(args)
    if args.raw and #args.raw==7 then -- \fade
        local a, r, num = {}, args.raw, tonumber
        a[1], a[2], a[3], a[4], a[5], a[6], a[7] = num(r[5])-num(r[4]), num(r[7])-num(r[6]), r[4], r[7], r[1], r[2], r[3]
        args.raw = a
    end
    startDuration, endDuration, startTime, endTime, startAlpha, midAlpha, endAlpha = self:getArgs(args,{0,0,0,0,255,0,255},true)

    self:readProps(args)
    self.startDuration, self.endDuration = ASSDuration{startDuration}, ASSDuration{endDuration}
    self.startTime, self.endTime = ASSTime{startTime}, ASSTime{endTime}
    self.startAlpha, self.midAlpha, self.endAlpha = ASSHex{startAlpha}, ASSHex{midAlpha}, ASSHex{endAlpha}

    if self.__tag.simple == nil then
        self.__tag.simple = self:setSimple(args.simple)
    end

    return self
end

function ASSFade:getTagParams(coerce)
    if self.__tag.simple then
        return self.startDuration:getTagParams(coerce), self.endDuration:getTagParams(coerce)
    else
        local t1, t4 = self.startTime:getTagParams(coerce), self.endTime:getTagParams(coerce)
        local t2 = t1 + self.startDuration:getTagParams(coerce)
        local t3 = t4 - self.endDuration:getTagParams(coerce)
        if not coerce then
             self:checkPositive(t2,t3)
             assertEx(t1<=t2 and t2<=t3 and t3<=t4, "fade times must evaluate to t1<=t2<=t3<=t4, got %d<=%d<=%d<=%d.",
                      t1,t2,t3,t4)
        end
        return self.startAlpha:getTagParams(coerce), self.midAlpha:getTagParams(coerce), self.endAlpha:getTagParams(coerce),
               math.min(t1,t2), util.clamp(t2,t1,t3), util.clamp(t3,t2,t4), math.max(t4,t3)
    end
end

function ASSFade:setSimple(state)
    if state==nil then
        state = self.startTime:equal(0) and self.endTime:equal(0) and
                self.startAlpha:equal(255) and self.midAlpha:equal(0) and self.endAlpha:equal(255)
    end
    self.__tag.simple, self.__tag.name = state, state and "fade_simple" or "fade"
    return state
end

ASSMove = createASSClass("ASSMove", ASSTagBase,
    {"startPos", "endPos", "startTime", "endTime"},
    {ASSPoint,ASSPoint,ASSTime,ASSTime}
)
function ASSMove:new(args)
    local startX, startY, endX, endY, startTime, endTime = self:getArgs(args, 0, true)

    assertEx(startTime<=endTime, "argument #4 (endTime) to %s may not be smaller than argument #3 (startTime), got %d>=%d.",
             self.typeName, endTime, startTime)

    self:readProps(args)
    self.startPos, self.endPos = ASSPoint{startX, startY}, ASSPoint{endX, endY}
    self.startTime, self.endTime = ASSTime{startTime}, ASSTime{endTime}

    if self.__tag.simple == nil then
        self.__tag.simple = self:setSimple(args.simple)
    end

    return self
end

function ASSMove:getTagParams(coerce)
    if self.__tag.simple or self.__tag.name=="move_simple" then
        return returnAll({self.startPos:getTagParams(coerce)}, {self.endPos:getTagParams(coerce)})
    else
        local t1,t2 = self.startTime:getTagParams(coerce), self.endTime:getTagParams(coerce)
        if not coerce then
             assertEx(t1<=t2, "move times must evaluate to t1<=t2, got %d<=%d.", t1,t2)
        end
        return returnAll({self.startPos:getTagParams(coerce)}, {self.endPos:getTagParams(coerce)},
                         {math.min(t1,t2)}, {math.max(t2,t1)})
    end
end

function ASSMove:setSimple(state)
    if state==nil then
        state = self.startTime:equal(0) and self.endTime:equal(0)
    end
    self.__tag.simple, self.__tag.name = state, state and "move_simple" or "move"
    return state
end

ASSString = createASSClass("ASSString", {ASSTagBase, ASSStringBase}, {"value"}, {"string"})

function ASSString:getTagParams(coerce)
    return coerce and tostring(self.value) or self:typeCheck(self.value)
end
ASSString.add, ASSString.mul, ASSString.div, ASSString.pow, ASSString.mod = ASSString.append, nil, nil, nil, nil


ASSToggle = createASSClass("ASSToggle", ASSTagBase, {"value"}, {"boolean"})
function ASSToggle:new(args)
    self.value = self:getArgs(args,false,true)
    self:readProps(args)
    self:typeCheck(self.value)
    return self
end

function ASSToggle:toggle(state)
    assertEx(type(state)=="boolean" or type(state)=="nil",
             "argument #1 (state) must be true, false or nil, got a %s.", type(state))
    self.value = state==nil and not self.value or state
    return self.value
end

function ASSToggle:getTagParams(coerce)
    if not coerce then self:typeCheck(self.value) end
    return self.value and 1 or 0
end

ASSIndexed = createASSClass("ASSIndexed", ASSNumber, {"value"}, {"number"}, {precision=0, positive=true})
function ASSIndexed:cycle(down)
    local min, max = self.__tag.range[1], self.__tag.range[2]
    if down then
        return self.value<=min and self:set(max) or self:add(-1)
    else
        return self.value>=max and self:set(min) or self:add(1)
    end
end

ASSAlign = createASSClass("ASSAlign", ASSIndexed, {"value"}, {"number"}, {range={1,9}, default=5})

function ASSAlign:up()
    if self.value<7 then return self:add(3)
    else return false end
end

function ASSAlign:down()
    if self.value>3 then return self:add(-3)
    else return false end
end

function ASSAlign:left()
    if self.value%3~=1 then return self:add(-1)
    else return false end
end

function ASSAlign:right()
    if self.value%3~=0 then return self:add(1)
    else return false end
end

function ASSAlign:centerV()
    if self.value<=3 then self:up()
    elseif self.value>=7 then self:down() end
end

function ASSAlign:centerH()
    if self.value%3==1 then self:right()
    elseif self.value%3==0 then self:left() end
end

function ASSAlign:getSet(pos)
    local val = self.value
    local set = { top = val>=7, centerV = val>3 and val<7, bottom = val<=3,
                  left = val%3==1, centerH = val%3==2, right = val%3==0 }
    return pos==nil and set or set[pos]
end

function ASSAlign:isTop() return self:getSet("top") end
function ASSAlign:isCenterV() return self:getSet("centerV") end
function ASSAlign:isBottom() return self:getSet("bottom") end
function ASSAlign:isLeft() return self:getSet("left") end
function ASSAlign:isCenterH() return self:getSet("centerH") end
function ASSAlign:isRight() return self:getSet("right") end

function ASSAlign:getPositionOffset(w, h)
    local x, y = {w, 0, w/2}, {h, h/2, 0}
    local off = ASSPoint{x[self.value%3+1], y[math.ceil(self.value/3)]}
    return off
end



ASSWeight = createASSClass("ASSWeight", ASSTagBase, {"weightClass","bold"}, {ASSNumber,ASSToggle})
function ASSWeight:new(args)
    local weight, bold = self:getArgs(args,{0,false},true)
                    -- also support signature ASSWeight{bold} without weight
    if args.raw or (#args==1 and not ASS.instanceOf(args[1], ASSWeight)) then
        weight, bold = weight~=1 and weight or 0, weight==1
    end
    self:readProps(args)
    self.bold = ASSToggle{bold}
    self.weightClass = ASSNumber{weight, tagProps={positive=true, precision=0}}
    return self
end

function ASSWeight:getTagParams(coerce)
    if self.weightClass.value >0 then
        return self.weightClass:getTagParams(coerce)
    else
        return self.bold:getTagParams(coerce)
    end
end

function ASSWeight:setBold(state)
    self.bold:set(type(state)=="nil" and true or state)
    self.weightClass.value = 0
end

function ASSWeight:toggle()
    self.bold:toggle()
end

function ASSWeight:setWeight(weightClass)
    self.bold:set(false)
    self.weightClass:set(weightClass or 400)
end

ASSWrapStyle = createASSClass("ASSWrapStyle", ASSIndexed, {"value"}, {"number"}, {range={0,3}, default=0})


ASSClipRect = createASSClass("ASSClipRect", ASSTagBase, {"topLeft", "bottomRight"}, {ASSPoint, ASSPoint})

function ASSClipRect:new(args)
    local left, top, right, bottom = self:getArgs(args, 0, true)
    self:readProps(args)

    self.topLeft = ASSPoint{left, top}
    self.bottomRight = ASSPoint{right, bottom}
    self:setInverse(self.__tag.inverse or false)
    return self
end

function ASSClipRect:getTagParams(coerce)
    self:setInverse(self.__tag.inverse or false)
    return returnAll({self.topLeft:getTagParams(coerce)}, {self.bottomRight:getTagParams(coerce)})
end

function ASSClipRect:getVect()
    local vect = ASS:createTag(ASS.tagNames[ASSClipVect][self.__tag.inverse and 2 or 1])
    return vect:drawRect(self.topLeft, self.bottomRight)
end

function ASSClipRect:getDrawing(trimDrawing, pos, an)
    if ASS.instanceOf(pos, ASSTagList) then
        pos, an = pos.tags.position, pos.tags.align
    end

    if not (pos and an) then
        if self.parent and self.parent.parent then
            local effTags = self.parent.parent:getEffectiveTags(-1, true, true, false).tags
            pos, an = pos or effTags.position, an or effTags.align
        end
    end

    return self:getVect():getDrawing(trimDrawing, pos, an)
end

function ASSClipRect:setInverse(state)
    state = state==nil and true or state
    self.__tag.inverse = state
    self.__tag.name = state and "iclip_rect" or "clip_rect"
    return state
end

function ASSClipRect:toggleInverse()
    return self:setInverse(not self.__tag.inverse)
end



--------------------- Drawing Classes ---------------------

ASSDrawing = createASSClass("ASSDrawing", ASSTagBase, {"contours"}, {"table"})
function ASSDrawing:new(args)
    -- TODO: support alternative signature for ASSLineDrawingSection
    local cmdMap, lastCmdType = ASS.classes.drawingCommandMappings
    -- construct from a compatible object
    -- note: does copy
    if ASS.instanceOf(args[1], ASSDrawing, nil, true) then
        local copy = args[1]:copy()
        self.contours, self.scale = copy.contours, copy.scale
        self.__tag.inverse = copy.__tag.inverse
    -- construct from a single string of drawing commands
    elseif args.raw or args.str then
        self.contours = {}
        local str = args.str or args.raw[1]
        if self.class == ASSClipVect then
            local _,sepIdx = str:find("^%d+,")
            self.scale = ASS:createTag("drawing", epIdx and tonumber(str:sub(0,sepIdx-1)) or 1)
            str = sepIdx and str:sub(sepIdx+1) or str
        else self.scale = ASS:createTag("drawing", args.scale or 1) end

        local cmdParts, i, j = str:split(" "), 1, 1
        local contour, c = {}, 1
        while i<=#cmdParts do
            local cmd, cmdType = cmdParts[i], cmdMap[cmdParts[i]]
            if cmdType == ASSDrawMove and i>1 and args.splitContours~=false then
                self.contours[c] = ASSDrawContour(contour)
                self.contours[c].parent = self
                contour, j, c = {}, 1, c+1
            end
            if cmdType == ASSDrawClose then
                contour[j] = ASSDrawClose()
            elseif cmdType or cmdParts[i]:find("^[%-%d%.]+$") and lastCmdType then
                if not cmdType then
                    i=i-1
                else lastCmdType = cmdType end
                local prmCnt = lastCmdType.__defProps.ords
                local prms = table.sliceArray(cmdParts,i+1,i+prmCnt)
                contour[j] = lastCmdType(unpack(prms))
                i = i+prmCnt
            else error(string.format("Error: Unsupported drawing Command '%s'.", cmdParts[i])) end
            i, j = i+1, j+1
        end
        if #contour>0 then
            self.contours[c] = ASSDrawContour(contour)
            self.contours[c].parent = self
        end

        if self.scale>=1 then
            self:div(2^(self.scale-1),2^(self.scale-1))
        end
    else
    -- construct from valid drawing commands, also accept contours and tables of drawing commands
    -- note: doesn't copy
        self.contours, self.scale = {}, ASS:createTag("drawing", args.scale or 1)
        local contour, c = {}, 1
        local j, cmdSet = 1, ASS.classes.drawingCommands
        for i=1,#args do
            assertEx(type(args[i])=="table",
                     "argument #%d is not a valid drawing object, contour or table, got a %s.", i, type(args[i]))
            if args[i].instanceOf then
                if args[i].instanceOf[ASSDrawContour] then
                    if #contour>0 then
                        self.contours[c] = ASSDrawContour(contour)
                        self.contours[c].parent, c = self, c+1
                    end
                    self.contours[c], c = args[i], c+1
                    contour, j = {}, 1
                elseif args[i].instanceOf[ASSDrawMove] and i>1 and args.splitContours~=false then
                    self.contours[c], c = ASSDrawContour(contour), c+1
                    contour, j = {args[i]}, 2
                elseif ASS.instanceOf(args[i], cmdSet) then
                    contour[j], j = args[i], j+1
                else error(string.format("argument #%d is not a valid drawing object or contour, got a %s.",
                                         i, args[i].class.typeName))
                end
            else
                for k=1,#args[i] do
                    assertEx(ASS.instanceOf(args[i][k],ASS.classes.drawingCommands),
                             "argument #%d to %s contains invalid drawing objects (#%d is a %s).",
                             i, self.typeName, k, ASS.instanceOf(args[i][k]) or type(args[i][k])
                    )
                    if args[i][k].instanceOf[ASSDrawMove] then
                        self.contours[c] = ASSDrawContour(contour)
                        self.contours[c].parent = self
                        contour, j, c = {args[i][k]}, 2, c+1
                    else contour[j], j = args[i][k], j+1 end
                end
            end
        end
        if #contour>0 then
            self.contours[c] = ASSDrawContour(contour)
            self.contours[c].parent = self
        end
    end
    self:readProps(args)
    return self
end

function ASSDrawing:callback(callback, start, end_, includeCW, includeCCW)
    local j, cntsDeleted = 1, false
    includeCW, includeCCW = default(includeCW, true), default(includeCCW, true)
    for i=1,#self.contours do
        if not (includeCW and includeCCW) and cnt.isCW==nil then
            cnt:getDirection()
        end
        if (includeCW or not self.isCW) and (includeCCW or self.isCW) then
            local res = callback(self.contours[i], self.contours, i, j)
            j=j+1
            if res==false then
                self.contours[i], cntsDeleted = nil, true
            elseif res~=nil and res~=true then
                self.contours[i], self.length = res, true
            end
        end
    end
    if cntsDeleted then
        self.contours = table.reduce(self.contours)
        self.length = nil
    end
end

function ASSDrawing:modCommands(callback, commandTypes, start, end_, includeCW, includeCCW)
    includeCW, includeCCW = default(includeCW, true), default(includeCCW, true)
    local cmdSet = {}
    if type(commandTypes)=="string" or ASS.instanceOf(commandTypes) then commandTypes={commandTypes} end
    if commandTypes then
        assertEx(type(commandTypes)=="table", "argument #2 must be either a table of strings or a single string, got a %s.",
                 type(commandTypes))
        for i=1,#commandTypes do
            cmdSet[commandTypes[i]] = true
        end
    end

    local matchedCmdCnt, matchedCntsCnt, cntsDeleted = 1, 1, false
    for i=1,#self.contours do
        local cnt = self.contours[i]
        if not (includeCW and includeCCW) and cnt.isCW==nil then
            cnt:getDirection()
        end
        if (includeCW or not cnt.isCW) and (includeCCW or cnt.isCW) then
            local cmdsDeleted = false
            for j=1,#cnt.commands do
                if not commandTypes or cmdSet[cnt.commands[j].__tag.name] or cmdSet[cnt.commands[j].class] then
                    local res = callback(cnt.commands[j], cnt.commands, j, matchedCmdCnt, i, matchedCntsCnt)
                    matchedCmdCnt = matchedCmdCnt + 1
                    if res==false then
                        cnt.commands[j], cmdsDeleted = nil, true
                    elseif res~=nil and res~=true then
                        cnt.commands[j] = res
                        cnt.length, cnt.isCW, self.length = nil, nil, nil
                    end
                end
            end
            matchedCntsCnt = matchedCntsCnt + 1
            if cmdsDeleted then
                cnt.commands = table.reduce(cnt.commands)
                cnt.length, cnt.isCW, self.length = nil, nil, nil
                if #cnt.commands == 0 then
                    self.contours[i], cntsDeleted = nil, true
                end
            end
        end
    end
    if cntsDeleted then self.contours = table.reduce(self.contours) end
end

function ASSDrawing:insertCommands(cmds, index)
    local prevCnt, addContour, a, newContour, n = #self.contours, {}, 1
    index = index or prevCnt
    assertEx(math.isInt(index) and index~=0,
             "argument #2 (index) must be an integer != 0, got '%s' of type %s.", tostring(index), type(index))
    assertEx(type(cmds)=="table",
           "argument #1 (cmds) must be either a drawing command object or a table of drawing commands, got a %s.", type(cmds))

    if index<0 then index=prevCnt+index+1 end
    local cntAtIdx = self.contours[index] or self.contours[prevCnt]
    if cmds.instanceOf then cmds = {cmds} end

    for i=1,#cmds do
        local cmdIsTbl = type(cmds[i])=="table"
        assertEx(cmdIsTbl and cmds[i].instanceOf,"command #%d must be a drawing command object, got a %s",
                 cmdIsTbl and cmd.typeName or type(cmds[i]))
        if cmds[i].instanceOf[ASSDrawMove] then
            if newContour then
                self:insertContours(ASSDrawContour(contour), math.min(index, #self.contours+1))
            end
            newContour, index, n = {cmds[i]}, index+1, 2
        elseif newContour then
            newContour[n], n = cmds[i], n+1
        else addContour[a], a = cmds[i], a+1 end
    end
    if #addContour>0 then cntAtIdx:insertCommands(addContour) end
    if newContour then
        self:insertContours(ASSDrawContour(contour), math.min(index, #self.contours+1))
    end
end

function ASSDrawing:insertContours(cnts, index)
    index = index or #self.contours+1

    assertEx(type(cnts)=="table", "argument #1 (cnts) must be either a single contour object or a table of contours, got a %s.",
             type(cnts))

    if cnts.compatible and cnts.compatible[ASSDrawing] then
        cnts = cnts:copy().contours
    elseif cnts.instanceOf then cnts = {cnts} end

    for i=1,#cnts do
        assertEx(ASS.instanceOf(cnts[i], ASSDrawContour), "can only insert objects of class %s, got a %s.",
                 ASSDrawContour.typeName, type(cnts[i])=="table" and cnts[i].typeName or type(cnts[i]))

        table.insert(self.contours, index+i-1, cnts[i])
        cnts[i].parent = self
    end
    if #cnts>0 then self.length = nil end

    return cnts
end

function ASSDrawing:getTagParams(coerce)
    local cmdStr, j = {}, 1
    for i=1,#self.contours do
        cmdStr[i] = self.contours[i]:getTagParams(self.scale, coerce)
    end
    return table.concat(cmdStr, " "), self.scale:getTagParams(coerce)
end

function ASSDrawing:commonOp(method, callback, default, x, y) -- drawing commands only have x and y in common
    for i=1,#self.contours do
        self.contours[i]:commonOp(method, callback, default, x, y)
    end
    return self
end

function ASSDrawing:drawRect(tl, br) -- TODO: contour direction
    local rect = ASSDrawContour{ASSDrawMove(tl), ASSDrawLine(br.x, tl.y), ASSDrawLine(br), ASSDrawLine(tl.x, br.y)}
    self:insertContours(rect)
    return self, rect
end

function ASSDrawing:flatten(coerce)
    local flatStr, _ = {}
    for i=1,#self.contours do
        _, flatStr[i] = self.contours[i]:flatten(coerce)
    end
    return self, table.concat(flatStr, " ")
end

function ASSDrawing:getLength()
    local totalLen, lens = 0, {}
    for i=1,#self.contours do
        local len, lenParts = self.contours[i]:getLength()
        table.joinInto(lens, lenParts)
        totalLen = totalLen+len
    end
    self.length = totalLen
    return totalLen, lens
end

function ASSDrawing:getCommandAtLength(len, noUpdate)
    if not (noUpdate and self.length) then self:getLength() end
    local currTotalLen = 0
    for i=1,#self.contours do
        local cnt = self.contours[i]
        if currTotalLen+cnt.length-len > -0.001 and cnt.length>0 then
            local cmd, remLen = cnt:getCommandAtLength(len, noUpdate)
            assert(cmd or i==#self.contours, "Unexpected Error: command at length not found in target contour.")
            return cmd, remLen, cnt, i
        else currTotalLen = currTotalLen + cnt.length - len end
    end
    return false
    -- error(string.format("Error: length requested (%02f) is exceeding the total length of the shape (%02f)",len,currTotalLen))
end

function ASSDrawing:getPositionAtLength(len, noUpdate, useCurveTime)
    if not (noUpdate and self.length) then self:getLength() end
    local cmd, remLen, cnt  = self:getCommandAtLength(len, true)
    if not cmd then return false end
    return cmd:getPositionAtLength(remLen, true, useCurveTime), cmd, cnt
end

function ASSDrawing:getAngleAtLength(len, noUpdate)
    if not (noUpdate and self.length) then self:getLength() end
    local cmd, remLen, cnt = self:getCommandAtLength(len, true)
    if not cmd then return false end

    local fCmd = cmd.instanceOf[ASSDrawBezier] and cmd.flattened:getCommandAtLength(remLen, true) or cmd
    return fCmd:getAngle(nil, false, true), cmd, cnt
end

function ASSDrawing:getExtremePoints(allowCompatible)
    if #self.contours==0 then return {w=0, h=0} end
    local ext = self.contours[1]:getExtremePoints(allowCompatible)

    for i=2,#self.contours do
        local pts = self.contours[i]:getExtremePoints(allowCompatible)
        if ext.top.y > pts.top.y then ext.top=pts.top end
        if ext.left.x > pts.left.x then ext.left=pts.left end
        if ext.bottom.y < pts.bottom.y then ext.bottom=pts.bottom end
        if ext.right.x < pts.right.x then ext.right=pts.right end
    end
    ext.w, ext.h = ext.right.x-ext.left.x, ext.bottom.y-ext.top.y
    return ext
end

function ASSDrawing:outline(x,y,mode)
    self.contours = self:getOutline(x,y,mode).contours
    self.length = nil
end

function ASSDrawing:getOutline(x,y,mode)
    assert(HAVE_YUTILS, YUtilsMissingMsg)
    y, mode = default(y,x), default(mode, "round")
    local outline = YUtils.shape.to_outline(YUtils.shape.flatten(self:getTagParams()),x,y,mode)
    return self.class{str=outline}
end
function ASSDrawing:rotate(angle)
    angle = default(angle,0)
    if ASS.instanceOf(angle,ASSNumber) then
        angle = angle:getTagParams(coerce)
    else assertEx(type(angle)=="number", "argument #1 (angle) must be either a number or a %s object, got a %s.",
         ASSNumber.typeName, ASS.instanceOf(angle) and ASS.instanceOf(angle).typeName or type(angle))
    end

    if angle%360~=0 then
        assert(HAVE_YUTILS, YUtilsMissingMsg)
        local shape = self:getTagParams()
        local bound = {YUtils.shape.bounding(shape)}
        local rotMatrix = YUtils.math.create_matrix().
                          translate((bound[3]-bound[1])/2,(bound[4]-bound[2])/2,0).rotate("z",angle).
                          translate(-bound[3]+bound[1]/2,(-bound[4]+bound[2])/2,0)
        shape = YUtils.shape.transform(shape,rotMatrix)
        self.contours = ASSDrawing{raw=shape}.contours
    end
    return self
end

function ASSDrawing:get()
    local commands, j = {}, 1
    for i=1, #self.contours do
        table.joinInto(commands, self.contours[i]:get())
    end
    return commands, self.scale:get()
end

function ASSDrawing:getSection()
    local section = ASSLineDrawingSection{}
    section.contours, section.scale = self.contours, self.scale
    return section
end

ASSDrawing.set, ASSDrawing.mod = nil, nil  -- TODO: check if these can be remapped/implemented in a way that makes sense, maybe work on strings


ASSClipVect = createASSClass("ASSClipVect", ASSDrawing, {"commands","scale"}, {"table", ASSNumber}, {}, {ASSDrawing})
--TODO: unify setInverse and toggleInverse for VectClip and RectClip by using multiple inheritance
function ASSClipVect:setInverse(state)
    state = state==nil and true or state
    self.__tag.inverse = state
    self.__tag.name = state and "iclip_vect" or "clip_vect"
    return state
end

function ASSClipVect:toggleInverse()
    return self:setInverse(not self.__tag.inverse)
end

function ASSClipVect:getDrawing(trimDrawing, pos, an)
    if ASS.instanceOf(pos, ASSTagList) then
        pos, an = pos.tags.position, pos.tags.align
    end

    if not (pos and an) then
        if self.parent and self.parent.parent then
            local effTags = self.parent.parent:getEffectiveTags(-1, true, true, false).tags
            pos, an = pos or effTags.position, an or effTags.align
        elseif not an then an=ASSAlign{7} end
    end

    assertEx(not pos or ASS.instanceOf(pos, ASSPoint, nil, true),
             "argument position must be an %d or a compatible object, got a %s.",
             ASSPoint.typeName, type(pos)=="table" and pos.typeName or type(pos))
    assertEx(ASS.instanceOf(an, ASSAlign),
             "argument align must be an %d or a compatible object, got a %s.",
             ASSAlign.typeName, type(pos)=="table" and an.typeName or type(an))

    local drawing = ASSLineDrawingSection{self}
    local ex = self:getExtremePoints()
    local anOff = an:getPositionOffset(ex.w, ex.h)

    if trimDrawing or not pos then
        drawing:sub(ex.left.x.value, ex.top.y.value)
        return drawing, ASS:createTag("position", ex.left.x, ex.top.y):add(anOff)
    else return drawing:add(anOff):sub(pos) end
end


ASSLineDrawingSection = createASSClass("ASSLineDrawingSection", ASSDrawing, {"commands","scale"}, {"table", ASSNumber}, {}, {ASSDrawing, ASSClipVect})
ASSLineDrawingSection.getStyleTable = ASSLineTextSection.getStyleTable
ASSLineDrawingSection.getEffectiveTags = ASSLineTextSection.getEffectiveTags
ASSLineDrawingSection.getString = ASSLineDrawingSection.getTagParams
ASSLineDrawingSection.getTagString = nil

function ASSLineDrawingSection:alignToOrigin(mode)
    mode = ASSAlign{mode or 7}
    local ex = self:getExtremePoints(true)
    local cmdOff = ASSPoint{ex.left.x, ex.top.y}
    local posOff = mode:getPositionOffset(ex.w, ex.h):add(cmdOff)
    self:sub(cmdOff)
    return posOff, ex
end

function ASSLineDrawingSection:getBounds(coerce)
    assert(HAVE_YUTILS, YUtilsMissingMsg)
    local bounds = {YUtils.shape.bounding(self:getString())}
    bounds.width = (bounds[3] or 0)-(bounds[1] or 0)
    bounds.height = (bounds[4] or 0)-(bounds[2] or 0)
    return bounds
end

function ASSLineDrawingSection:getClip(inverse)
    -- TODO: scale support
    local effTags, ex = self.parent:getEffectiveTags(-1, true, true, false).tags , self:getExtremePoints()
    local clip = ASS:createTag(ASS.tagNames[ASSClipVect][inverse and 2 or 1], self)
    local anOff = effTags.align:getPositionOffset(ex.w, ex.h)
    return clip:add(effTags.position):sub(anOff)
end


ASSDrawContour = createASSClass("ASSDrawContour", ASSBase, {"commands"}, {"table"})
function ASSDrawContour:new(args)
    local cmds, clsSet = {}, ASS.classes.drawingCommands
    for i=1,#args do
        assertEx(type(args[i])=="table" and args[i].instanceOf and clsSet[args[i].class],
                 "argument #%d is not a valid drawing command object (%s).", i, args[i].typeName or type(args[i]))
        if i==1 then
            assertEx(args[i].instanceOf[ASSDrawMove], "first drawing command of a contour must be of class %s, got a %s.",
                     ASSDrawMove.typeName, args[i].typeName)
        end
        cmds[i] = args[i]
        cmds[i].parent = self
    end
    self.commands = cmds
    return self
end

function ASSDrawContour:callback(callback, commandTypes, getPoints)
    local cmdSet = {}
    if type(commandTypes)=="string" or ASS.instanceOf(commandTypes) then commandTypes={commandTypes} end
    if commandTypes then
        assertEx(type(commandTypes)=="table", "argument #2 must be either a table of strings or a single string, got a %s.",
                 type(commandTypes))
        for i=1,#commandTypes do
            cmdSet[commandTypes[i]] = true
        end
    end

    local j, cmdsDeleted = 1, false
    for i=1,#self.commands do
        local cmd = self.commands[i]
        if not commandTypes or cmdSet[cmd.__tag.name] or cmdSet[cmd.class] then
            if getPoints and not cmd.compatible[ASSPoint] then
                local pointsDeleted = false
                for p=1,#cmd.__meta__.order do
                    local res = callback(cmd[cmd.__meta__.order[p]], self.commands, i, j, cmd, p)
                    j=j+1
                    if res==false then
                        cmdsDeleted, pointsDeleted = true, true   -- deleting a single point causes the whole command to be deleted
                    elseif res~=nil and res~=true then
                        local class = cmd.__meta__.types[p]
                        cmd[cmd.__meta__.order[p]] = res.instanceOf[class] and res or class{res}
                    end
                end
                if pointsDeleted then self.commands[i] = nil end
            else
                local res = callback(cmd, self.commands, i, j)
                j=j+1
                if res==false then
                    self.commands[i], cmdsDeleted = nil, true
                elseif res~=nil and res~=true then
                    self.commands[i] = res
                end
            end
        end
    end
    if cmdsDeleted then self.commands = table.reduce(self.commands) end
    if j>1 then
        self.length, self.isCW = nil, nil
        if self.parent then self.parent.length=nil end
    end
end

function ASSDrawContour:expand(x, y)
    x = default(x,1)
    y = default(y,x)

    assertEx(type(x)=="number" and type(y)=="number", "x and y must be a number or nil, got x=%s (%s) and y=%s (%s).",
             tostring(x), type(x), tostring(y), type(y))
    if x==0 and y==0 then return self end
    assertEx(x>=0 and y>=0 or x<=0 and y<=0,
             "cannot expand and inpand at the same time (sign must be the same for x and y); got x=%d, y=%d.", x, y)

    self:getDirection()
    local newCmds, sameDir = {}
    if x<0 or y<0 then
        x, y = math.abs(x), math.abs(y)
        sameDir = self.isCW==false
    else sameDir = self.isCW==true end
    local outline = self:getOutline(x, y)

    -- may violate the "one move per contour" principle
    self.commands, self.length, self.isCW = {}, nil, nil

    for i=sameDir and 2 or 1, #outline.contours, 2 do
        self:insertCommands(outline.contours[i].commands, -1, true)
    end
    return self
end

function ASSDrawContour:insertCommands(cmds, index, acceptMoves)
    local prevCnt, inserted, clsSet = #self.commands, {}, ASS.classes.drawingCommands
    index = default(index, math.max(prevCnt,1))
    assertEx(math.isInt(index) and index~=0,
           "argument #2 (index) must be an integer != 0, got '%s' of type %s.", tostring(index), type(index))
    assertEx(type(cmds)=="table",
           "argument #1 (cmds) must be either a drawing command object or a table of drawing commands, got a %s.", type(cmds))

    if cmds.class==ASSDrawContour then
        accceptMoves, cmds = true, cmds.commands
    elseif cmds.instanceOf then cmds = {cmds} end

    for i=1,#cmds do
        local cmdIsTbl, cmd = type(cmds[i])=="table", cmds[i]
        assertEx(cmdIsTbl and cmd.class, "command #%d must be a drawing command object, got a %s",
                 i, cmdIsTbl and cmd.typeName or type(cmd))
        assertEx(clsSet[cmd.class] and (not cmd.instanceOf[ASSDrawMove] or acceptMoves),
                 "command #%d must be a drawing command object, but not a %s; got a %s", ASSDrawMove.typeName, cmd.typeName)

        local insertIdx = index<0 and prevCnt+index+i+1 or index+i-1
        table.insert(self.commands, insertIdx, cmd)
        cmd.parent = self
        inserted[i] = self.commands[insertIdx]
    end
    if #cmds>0 then
        self.length, self.isCW = nil, nil
        if self.parent then self.parent.length = nil end
    end
    return #cmds>1 and inserted or inserted[1]
end

function ASSDrawContour:flatten(coerce)
    assert(HAVE_YUTILS, YUtilsMissingMsg)
    local flatStr = YUtils.shape.flatten(self:getTagParams(coerce))
    local flattened = ASSDrawing{str=flatStr, tagProps=self.__tag}
    self.commands = flattened.contours[1].commands
    return self, flatStr
end

function ASSDrawContour:get()
    local commands, j = {}, 1
    for i=1,#self.commands do
        commands[j] = self.commands[i].__tag.name
        local params = {self.commands[i]:get()}
        table.joinInto(commands, params)
        j=j+#params+1
    end
    return commands
end

function ASSDrawContour:getCommandAtLength(len, noUpdate)
    if not (noUpdate and self.length) then self:getLength() end
    local currTotalLen, nextTotalLen = 0
    for i=1,#self.commands do
        local cmd = self.commands[i]
        nextTotalLen = currTotalLen + cmd.length
        if nextTotalLen-len > -0.001 and cmd.length>0
        and not (cmd.instanceOf[ASSDrawMove] or cmd.instanceOf[ASSDrawMoveNc]) then
            return cmd, math.max(len-currTotalLen,0)
        else currTotalLen = nextTotalLen end
    end
    return false
    -- error(string.format("Error: length requested (%02f) is exceeding the total length of the shape (%02f)",len,currTotalLen))
end

function ASSDrawContour:getDirection()
    local angle, vec = ASS:createTag("angle", 0)
    assertEx(self.commands[1].instanceOf[ASSDrawMove], "first drawing command must be a %s, got a %s.",
             ASSDrawMove.typeName, self.commands[1].typeName)

    local p0, p1 = self.commands[1]
    self:callback(function(point, cmds, i, j, cmd, p)
        if j==2 then p1 = point
        elseif j>2 then
            local vec0, vec1 = p1:copy():sub(p0), point:copy():sub(p1)
            angle:add(vec1:getAngle(vec0, true))
            p0, p1 = p1, point
        end
    end, nil, true)
    self.isCW = angle>=0
    return self.isCW
end

function ASSDrawContour:getExtremePoints(allowCompatible)
    local top, left, bottom, right
    for i=1,#self.commands do
        local pts = self.commands[i]:getPoints(allowCompatible)
        for i=1,#pts do
            if not top or top.y > pts[i].y then top=pts[i] end
            if not left or left.x > pts[i].x then left=pts[i] end
            if not bottom or bottom.y < pts[i].y then bottom=pts[i] end
            if not right or right.x < pts[i].x then right=pts[i] end
        end
    end
    return {top=top, left=left, bottom=bottom, right=right, w=right.x-left.x, h=bottom.y-top.y,
            bounds={left.x.value, top.y.value, right.x.value, bottom.y.value}}
end

function ASSDrawContour:getLength()
    local totalLen, lens = 0, {}
    for i=1,#self.commands do
        local len = self.commands[i]:getLength(self.commands[i-1])
        lens[i], totalLen = len, totalLen+len
    end
    self.length = totalLen
    return totalLen, lens
end

function ASSDrawContour:getPositionAtLength(len, noUpdate, useCurveTime)
    if not (noUpdate and self.length) then self:getLength() end
    local cmd, remLen  = self:getCommandAtLength(len, true)
    if not cmd then return false end
    return cmd:getPositionAtLength(remLen, true, useCurveTime), cmd
end

function ASSDrawContour:getAngleAtLength(len, noUpdate)
    if not (noUpdate and self.length) then self:getLength() end
    local cmd, remLen = self:getCommandAtLength(len, true)
    if not cmd then return false end

    local fCmd = cmd.instanceOf[ASSDrawBezier] and cmd.flattened:getCommandAtLength(remLen, true) or cmd
    return fCmd:getAngle(nil, false, true), cmd
end

function ASSDrawContour:getTagParams(scale, coerce)
    scale = (scale or self.parent and self.parent.scale):get() or 1
    local cmdStr, j, lastCmdType = {}, 1
    for i=1,#self.commands do
        local cmd = self.commands[i]
        if lastCmdType ~= cmd.__tag.name then
            lastCmdType = cmd.__tag.name
            cmdStr[j], j = lastCmdType, j+1
        end
        local params={cmd:getTagParams(coerce)}
        for p=1,#params do
            cmdStr[j] = scale>1 and params[p]*(2^(scale-1)) or params[p]
            j = j+1
        end
    end
    return table.concat(cmdStr, " ")
end

function ASSDrawContour:commonOp(method, callback, default, x, y) -- drawing commands only have x and y in common
    if ASS.instanceOf(x, ASSPoint, nil, true) then
        x, y = x:get()
    end
    for i=1,#self.commands do
        self.commands[i][method](self.commands[i],x,y)
    end
    return self
end

ASSDrawContour.add, ASSDrawContour.sub, ASSDrawContour.mul, ASSDrawContour.div, ASSDrawContour.mod, ASSDrawContour.pow =
ASSTagBase.add, ASSTagBase.sub, ASSTagBase.mul, ASSTagBase.div, ASSTagBase.mod, ASSTagBase.pow

function ASSDrawContour:getOutline(x, y, mode, splitContours)
    assert(HAVE_YUTILS, YUtilsMissingMsg)
    y, mode = default(y,x), default(mode, "round")
    local outline = YUtils.shape.to_outline(YUtils.shape.flatten(self:getTagParams()),x,y,mode)
    return (self.parent and self.parent.class or ASSDrawing){str=outline, splitContours=splitContours}
end

function ASSDrawContour:outline(x, y, mode)
    -- may violate the "one move per contour" principle
    self.commands = self:getOutline(x, y, mode, false).contours[1].commands
    self.length, self.isCW = nil, nil
end

function ASSDrawContour:rotate(angle)
    ASSDrawing.rotate(self, angle)
    self.commands = self.contours[1]  -- rotating a contour should produce no additional contours
    self.contours = nil
    return self
end

--------------------- Unsupported Tag Classes and Stubs ---------------------

ASSUnknown = createASSClass("ASSUnknown", ASSString, {"value"}, {"string"})
ASSUnknown.add, ASSUnknown.sub, ASSUnknown.mul, ASSUnknown.div, ASSUnknown.pow, ASSUnknown.mod = nil, nil, nil, nil, nil, nil

ASSTransform = createASSClass("ASSTransform", ASSTagBase, {"tags", "startTime", "endTime", "accel"},
                                                          {ASSLineTagSection, ASSTime, ASSTime, ASSNumber})

function ASSTransform:new(args)
    self:readProps(args)
    local names, tagName = ASS.tagNames[ASSTransform], self.__tag.name
    if args.raw then
        local r = {}
        if tagName == names[1] then        -- \t(<accel>,<style modifiers>)
            r[1], r[4] = args.raw[1], args.raw[2]
        elseif tagName == names[2] then    -- \t(<t1>,<t2>,<accel>,<style modifiers>)
            r[1], r[2], r[3], r[4] = args.raw[4], args.raw[1], args.raw[2], args.raw[3]
        elseif tagName == names[3] then    -- \t(<t1>,<t2>,<style modifiers>)
            r[1], r[2], r[3] = args.raw[3], args.raw[1], args.raw[2]
        else r = args.raw end
        args.raw = r
    end
    tags, startTime, endTime, accel = self:getArgs(args,{"",0,0,1},true)

    self.tags, self.accel = ASSLineTagSection(tags,args.transformableOnly), ASSNumber{accel, tagProps={positive=true}}
    self.startTime, self.endTime = ASSTime{startTime}, ASSTime{endTime}
    return self
end

function ASSTransform:changeTagType(type_)
    local names = ASS.tagNames[ASSTransform]
    if not type_ then
        local noTime = self.startTime:equal(0) and self.endTime:equal(0)
        self.__tag.name = self.accel:equal(1) and (noTime and names[4] or names[3]) or noTime and names[1] or names[2]
        self.__tag.typeLocked = false
    else
        assertEx(names[type], "invalid transform type '%s'.", tostring(type))
        self.__tag.name, self.__tag.typeLocked = type_, true
    end
    return self.__tag.name, self.__tag.typeLocked
end

function ASSTransform:getTagParams(coerce)

    if not self.__tag.typeLocked then
        self:changeTagType()
    end

    local names, tagName = ASS.tagNames[ASSTransform], self.__tag.name
    local t1, t2 = self.startTime:getTagParams(coerce), self.endTime:getTagParams(coerce)
    if coerce then
        t2 = util.max(t1, t2)
    else assertEx(t1<=t2, "transform start time must not be greater than the end time, got %d <= %d.", t1, t2) end

    if tagName == names[4] then
        return self.tags:getString(coerce)
    elseif tagName == names[1] then                                         -- \t(<accel>,<style modifiers>)
        return self.accel:getTagParams(coerce), self.tags:getString(coerce)
    elseif tagName == names[3] then                                         -- \t(<t1>,<t2>,<style modifiers>)
        return t1, t2, self.tags:getString(coerce)
    elseif tagName == names[2] then                                         -- \t(<t1>,<t2>,<accel>,<style modifiers>)
        return t1, t2, self.accel:getTagParams(coerce), self.tags:getString(coerce)
    else error("Error: invalid transform type: " .. tostring(type)) end

end
--------------------- Drawing Command Classes ---------------------

ASSDrawBase = createASSClass("ASSDrawBase", ASSTagBase, {}, {})
function ASSDrawBase:new(...)
    local args = {self:getArgs({...}, 0, true)}

    if self.compatible[ASSPoint] then
        self.x, self.y = ASSNumber{args[1]}, ASSNumber{args[2]}
    else
        for i=1,#args,2 do
            local j = (i+1)/2
            self[self.__meta__.order[j]] = self.__meta__.types[j]{args[i],args[i+1]}
        end
    end
    return self
end

function ASSDrawBase:getTagParams(coerce)
    local params, parts = self.__meta__.order, {}
    local i, j = 1, 1
    while i<=self.__meta__.rawArgCnt do
        parts[i], parts[i+1] = self[params[j]]:getTagParams(coerce)
        i, j = i+self[params[j]].__meta__.rawArgCnt, j+1
    end
    return table.concat(parts, " ")
end

function ASSDrawBase:getLength(prevCmd)
    assert(HAVE_YUTILS, YUtilsMissingMsg)
    -- get end coordinates (cursor) of previous command
    local x0, y0 = 0, 0
    if prevCmd and prevCmd.__tag.name == "b" then
        x0, y0 = prevCmd.p3:get()
    elseif prevCmd then x0, y0 = prevCmd:get() end

    -- save cursor for further processing
    self.cursor = ASSPoint{x0, y0}

    local name, len = self.__tag.name, 0
    if name == "b" then
        local shapeSection = ASSDrawing{ASSDrawMove(self.cursor:get()),self}
        self.flattened = ASSDrawing{str=YUtils.shape.flatten(shapeSection:getTagParams())} --save flattened shape for further processing
        len = self.flattened:getLength()
    elseif name =="m" or name == "n" then len=0
    elseif name =="l" then
        local x, y = self:get()
        len = YUtils.math.distance(x-x0, y-y0)
    end
    -- save length for further processing
    self.length = len
    return len
end

function ASSDrawBase:getPositionAtLength(len, noUpdate, useCurveTime)
    assert(HAVE_YUTILS, YUtilsMissingMsg)
    if not (self.length and self.cursor and noUpdate) then self.parent:getLength() end
    local name, pos = self.__tag.name
    if name == "b" and useCurveTime then
        local px, py = YUtils.math.bezier(math.min(len/self.length,1), {{self.cursor:get()},{self.p1:get()},{self.p2:get()},{self.p3:get()}})
        pos = ASSPoint{px, py}
    elseif name == "b" then
        pos = self:getFlattened(true):getPositionAtLength(len, true)   -- we already know this data is up-to-date because self.parent:getLength() was run
    elseif name == "l" then
        pos = ASSPoint{self:copy():ScaleToLength(len,true)}
    elseif name == "m" then
        pos = ASSPoint{self}
    end
    pos.__tag.name = "position"
    return pos
end

function ASSDrawBase:getPoints(allowCompatible)
    return allowCompatible and {self} or {ASSPoint{self}}
end

ASSDrawMove = createASSClass("ASSDrawMove", ASSDrawBase, {"x", "y"}, {ASSNumber, ASSNumber}, {name="m", ords=2}, {ASSPoint})
ASSDrawMoveNc = createASSClass("ASSDrawMoveNc", ASSDrawBase, {"x", "y"}, {ASSNumber, ASSNumber}, {name="n", ords=2}, {ASSDrawMove, ASSPoint})
ASSDrawLine = createASSClass("ASSDrawLine", ASSDrawBase, {"x", "y"}, {ASSNumber, ASSNumber}, {name="l", ords=2}, {ASSPoint, ASSDrawMove, ASSDrawMoveNc})
ASSDrawBezier = createASSClass("ASSDrawBezier", ASSDrawBase, {"p1","p2","p3"}, {ASSPoint, ASSPoint, ASSPoint}, {name="b", ords=6})
ASSDrawClose = createASSClass("ASSDrawClose", ASSDrawBase, {}, {}, {name="c", ords=0})
--- TODO: b-spline support

function ASSDrawClose:getPoints()
    return {}
end

function ASSDrawLine:ScaleToLength(len,noUpdate)
    assert(HAVE_YUTILS, YUtilsMissingMsg)
    if not (self.length and self.cursor and noUpdate) then self.parent:getLength() end
    self:sub(self.cursor)
    self:set(self.cursor:copy():add(YUtils.math.stretch(self.x.value, self.y.value, 0, len)))
    return self
end

function ASSDrawLine:getAngle(ref, vectAngle, noUpdate)
    if not ref then
        if not (self.cursor and noUpdate) then self.parent:getLength() end
        ref = self.cursor
    end
    return ASSPoint.getAngle(self, ref, vectAngle)
end

function ASSDrawBezier:commonOp(method, callback, default, ...)
    local args, j, valNames = {...}, 1, self.__meta__.order
    if #args<=2 then -- special case to allow common operation on all x an y values of a vector drawing
        args[3], args[4], args[5], args[6] = args[1], args[2], args[1], args[2]
        if type(default)=="table" and #default<=2 then
            default = {default[1], default[2], default[1], default[2]}
        end
    end
    args = {self:getArgs(args, default, false)}
    for i=1,#valNames do
        local subCnt = #self[valNames[i]].__meta__.order
        local subArgs = table.sliceArray(args,j,j+subCnt-1)
        self[valNames[i]][method](self[valNames[i]],unpack(subArgs))
        j=j+subCnt
    end
    return self
end

function ASSDrawBezier:getFlattened(noUpdate)
    assert(HAVE_YUTILS, YUtilsMissingMsg)
    if not (noUpdate and self.flattened) then
        if not (noUpdate and self.cursor) then
            self.parent:getLength()
        end
        local shapeSection = ASSDrawing{ASSDrawMove(self.cursor:get()),self}
        self.flattened = ASSDrawing{str=YUtils.shape.flatten(shapeSection:getTagParams())}
    end
    return self.flattened
end

function ASSDrawBezier:getPoints()
    return {self.p1, self.p2, self.p3}
end

----------- Tag Mapping -------------

ASSFoundation = createASSClass("ASSFoundation")
function ASSFoundation:new()
    self.tagMap = {
        scale_x =           {overrideName="\\fscx",  type=ASSNumber,    pattern="\\fscx([%d%.]+)",                    format="\\fscx%.3N",
                             sort=6, props={transformable=true}},
        scale_y =           {overrideName="\\fscy",  type=ASSNumber,    pattern="\\fscy([%d%.]+)",                    format="\\fscy%.3N",
                             sort=7, props={transformable=true}},
        align =             {overrideName="\\an",    type=ASSAlign,     pattern="\\an([1-9])",                        format="\\an%d",
                             sort=1, props={global=true}},
        angle =             {overrideName="\\frz",   type=ASSNumber,    pattern="\\frz?([%-%d%.]+)",                  format="\\frz%.3N",
                             sort=8, props={transformable=true}},
        angle_y =           {overrideName="\\fry",   type=ASSNumber,    pattern="\\fry([%-%d%.]+)",                   format="\\fry%.3N",
                             sort=9, props={transformable=true}, default={0}},
        angle_x =           {overrideName="\\frx",   type=ASSNumber,    pattern="\\frx([%-%d%.]+)",                   format="\\frx%.3N",
                             sort=10, props={transformable=true}, default={0}},
        outline =           {overrideName="\\bord",  type=ASSNumber,    pattern="\\bord([%d%.]+)",                    format="\\bord%.2N",
                             sort=20, props={positive=true, transformable=true}},
        outline_x =         {overrideName="\\xbord", type=ASSNumber,    pattern="\\xbord([%d%.]+)",                   format="\\xbord%.2N",
                             sort=21, props={positive=true, transformable=true}},
        outline_y =         {overrideName="\\ybord", type=ASSNumber,    pattern="\\ybord([%d%.]+)",                   format="\\ybord%.2N",
                             sort=22, props={positive=true, transformable=true}},
        shadow =            {overrideName="\\shad",  type=ASSNumber,    pattern="\\shad([%-%d%.]+)",                  format="\\shad%.2N",
                             sort=23, props={transformable=true}},
        shadow_x =          {overrideName="\\xshad", type=ASSNumber,    pattern="\\xshad([%-%d%.]+)",                 format="\\xshad%.2N",
                             sort=24, props={transformable=true}},
        shadow_y =          {overrideName="\\yshad", type=ASSNumber,    pattern="\\yshad([%-%d%.]+)",                 format="\\yshad%.2N",
                             sort=25, props={transformable=true}},
        reset =             {overrideName="\\r",     type=ASSString,    pattern="\\r([^\\}]*)",                       format="\\r%s",
                             props={transformable=true}},
        alpha =             {overrideName="\\alpha", type=ASSHex,       pattern="\\alpha&H(%x%x)&",                   format="\\alpha&H%02X&",
                             sort=30, props={transformable=true, masterAlpha=true}, default={0}},
        alpha1 =            {overrideName="\\1a",    type=ASSHex,       pattern="\\1a&H(%x%x)&",                      format="\\1a&H%02X&",
                             sort=31, props={transformable=true, childAlpha=true}},
        alpha2 =            {overrideName="\\2a",    type=ASSHex,       pattern="\\2a&H(%x%x)&",                      format="\\2a&H%02X&",
                             sort=32, props={transformable=true, childAlpha=true}},
        alpha3 =            {overrideName="\\3a",    type=ASSHex,       pattern="\\3a&H(%x%x)&",                      format="\\3a&H%02X&",
                             sort=33, props={transformable=true, childAlpha=true}},
        alpha4 =            {overrideName="\\4a",    type=ASSHex,       pattern="\\4a&H(%x%x)&",                      format="\\4a&H%02X&",
                             sort=34, props={transformable=true, childAlpha=true}},
        color =             {overrideName="\\c",     type=ASSColor,
                             props={name="color1", transformable=true, pseudo=true}},
        color1 =            {overrideName="\\1c",    type=ASSColor,     pattern="\\1?c&H(%x%x)(%x%x)(%x%x)&",         format="\\1c&H%02X%02X%02X&",  friendlyName="\\1c & \\c",
                             sort=26, props={transformable=true}},
        color2 =            {overrideName="\\2c",    type=ASSColor,     pattern="\\2c&H(%x%x)(%x%x)(%x%x)&",          format="\\2c&H%02X%02X%02X&",
                             sort=27, props={transformable=true}},
        color3 =            {overrideName="\\3c",    type=ASSColor,     pattern="\\3c&H(%x%x)(%x%x)(%x%x)&",          format="\\3c&H%02X%02X%02X&",
                             sort=28, props={transformable=true}},
        color4 =            {overrideName="\\4c",    type=ASSColor,     pattern="\\4c&H(%x%x)(%x%x)(%x%x)&",          format="\\4c&H%02X%02X%02X&",
                             sort=29, props={transformable=true}},
        clip_vect =         {overrideName="\\clip",  type=ASSClipVect,  pattern="\\clip%(([mnlbspc] .-)%)",           format="\\clip(%s)",         friendlyName="\\clip (Vector)",
                             sort=41, props={global=true, clip=true}},
        iclip_vect =        {overrideName="\\iclip", type=ASSClipVect,  pattern="\\iclip%(([mnlbspc] .-)%)",          format="\\iclip(%s)",        friendlyName="\\iclip (Vector)",
                             sort=42, props={inverse=true, global=true, clip=true}, default={"m 0 0 l 0 0 0 0 0 0 0 0"}},
        clip_rect =         {overrideName="\\clip",  type=ASSClipRect,  pattern="\\clip%(([%-%d%.]+),([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)%)", format="\\clip(%.2N,%.2N,%.2N,%.2N)", friendlyName="\\clip (Rectangle)",
                             sort=39, props={transformable=true, global=false, clip=true}},
        iclip_rect =        {overrideName="\\iclip", type=ASSClipRect,  pattern="\\iclip%(([%-%d%.]+),([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)%)", format="\\iclip(%.2N,%.2N,%.2N,%.2N)", friendlyName="\\iclip (Rectangle)",
                             sort=40, props={inverse=true, global=false, transformable=true, clip=true}, default={0,0,0,0}},
        drawing =           {overrideName="\\p",     type=ASSNumber,    pattern="\\p(%d+)",                           format="\\p%d",
                             sort=44, props={positive=true, integer=true, precision=0}, default={0}},
        blur_edges =        {overrideName="\\be",    type=ASSNumber,    pattern="\\be([%d%.]+)",                      format="\\be%.2N",
                             sort=36, props={positive=true, transformable=true}, default={0}},
        blur =              {overrideName="\\blur",  type=ASSNumber,    pattern="\\blur([%d%.]+)",                    format="\\blur%.2N",
                             sort=35, props={positive=true, transformable=true}, default={0}},
        shear_x =           {overrideName="\\fax",   type=ASSNumber,    pattern="\\fax([%-%d%.]+)",                   format="\\fax%.2N",
                             sort=11, props={transformable=true}, default={0}},
        shear_y =           {overrideName="\\fay",   type=ASSNumber,    pattern="\\fay([%-%d%.]+)",                   format="\\fay%.2N",
                             sort=12, props={transformable=true}, default={0}},
        bold =              {overrideName="\\b",     type=ASSWeight,    pattern="\\b(%d+)",                           format="\\b%d",
                             sort=16},
        italic =            {overrideName="\\i",     type=ASSToggle,    pattern="\\i([10])",                          format="\\i%d",
                             sort=17},
        underline =         {overrideName="\\u",     type=ASSToggle,    pattern="\\u([10])",                          format="\\u%d",
                             sort=18},
        strikeout =         {overrideName="\\s",     type=ASSToggle,    pattern="\\s([10])",                          format="\\s%d",
                             sort=19},
        spacing =           {overrideName="\\fsp",   type=ASSNumber,    pattern="\\fsp([%-%d%.]+)",                   format="\\fsp%.2N",
                             sort=15, props={transformable=true}},
        fontsize =          {overrideName="\\fs",    type=ASSNumber,    pattern="\\fs([%d%.]+)",                      format="\\fs%.2N",
                             sort=14, props={positive=true, transformable=true}},
        fontname =          {overrideName="\\fn",    type=ASSString,    pattern="\\fn([^\\}]*)",                      format="\\fn%s",
                             sort=13},
        k_fill =            {overrideName="\\k",     type=ASSDuration,  pattern="\\k([%d]+)",                         format="\\k%d",
                             sort=45, props={scale=10, karaoke=true}, default={0}},
        k_sweep =           {overrideName="\\kf",    type=ASSDuration,  pattern="\\kf([%d]+)",                        format="\\kf%d",
                             sort=46, props={scale=10, karaoke=true}, default={0}},
        k_sweep_alt =       {overrideName="\\K",     type=ASSDuration,  pattern="\\K([%d]+)",                         format="\\K%d",
                             sort=47, props={scale=10, karaoke=true}, default={0}},
        k_bord =            {overrideName="\\ko",    type=ASSDuration,  pattern="\\ko([%d]+)",                        format="\\ko%d",
                             sort=48, props={scale=10, karaoke=true}, default={0}},
        position =          {overrideName="\\pos",   type=ASSPoint,     pattern="\\pos%(([%-%d%.]+),([%-%d%.]+)%)",   format="\\pos(%.3N,%.3N)",
                             sort=2, props={global=true}},
        move_simple =       {overrideName="\\move",  type=ASSMove,      pattern="\\move%(([%-%d%.]+),([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)%)", format="\\move(%.3N,%.3N,%.3N,%.3N)", friendlyName="\\move (Simple)",
                             sort=3, props={simple=true, global=true}},
        move =              {overrideName="\\move",  type=ASSMove,      pattern="\\move%(([%-%d%.]+),([%-%d%.]+),([%-%d%.]+),([%-%d%.]+),(%d+),(%d+)%)", format="\\move(%.3N,%.3N,%.3N,%.3N,%.3N,%.3N)", friendlyName="\\move (w/ Time)",
                             sort=4, props={global=true}},
        origin =            {overrideName="\\org",   type=ASSPoint,     pattern="\\org%(([%-%d%.]+),([%-%d%.]+)%)",   format="\\org(%.3N,%.3N)",
                             sort=5, props={global=true}},
        wrapstyle =         {overrideName="\\q",     type=ASSWrapStyle, pattern="\\q(%d)",                            format="\\q%d",
                             sort=43, props={global=true}, default={0}},
        fade_simple =       {overrideName="\\fad",   type=ASSFade,      pattern="\\fad%((%d+),(%d+)%)",               format="\\fad(%d,%d)",
                             sort=37, props={simple=true, global=true}, default={0,0}},
        fade =              {overrideName="\\fade",  type=ASSFade,      pattern="\\fade%((.-)%)",                     format="\\fade(%d,%d,%d,%d,%d,%d,%d)",
                             sort=38, props={global=true}, default={255,0,255,0,0,0,0}},
        transform =         {overrideName="\\t",     type=ASSTransform,
                             props={pseudo=true}},
        transform_simple =  {overrideName="\\t",     type=ASSTransform, pattern="\\t%(([^,]+)%)",                     format="\\t(%s)"},
        transform_accel =   {overrideName="\\t",     type=ASSTransform, pattern="\\t%(([%d%.]+),([^,]+)%)",           format="\\t(%.2N,%s)"},
        transform_time =    {overrideName="\\t",     type=ASSTransform, pattern="\\t%(([%-%d]+),([%-%d]+),([^,]+)%)", format="\\t(%.2N,%.2N,%s)"},
        transform_complex = {overrideName="\\t",     type=ASSTransform, pattern="\\t%(([%-%d]+),([%-%d]+),([%d%.]+),([^,]+)%)", format="\\t(%.2N,%.2N,%.2N,%s)"},
        unknown =           {                        type=ASSUnknown,                                                 format="%s", friendlyName="Unknown Tag",
                             sort=98},
        junk =              {                        type=ASSUnknown,                                                 format="%s", friendlyName="Junk",
                             sort=99}
    }

    self.tagNames, self.toFriendlyName, self.toTagName, self.tagSortOrder = {
        all = table.keys(self.tagMap),
        noPos = table.keys(self.tagMap, "position"),
        clips = self:getTagsNamesFromProps{clip=true},
        karaoke = self:getTagsNamesFromProps{karaoke=true},
        childAlpha = self:getTagsNamesFromProps{childAlpha=true}
    }, {}, {}, {}

    for name,tag in pairs(self.tagMap) do
        -- insert tag name into props
        tag.props = tag.props or {}
        tag.props.name = tag.props.name or name
        -- generate properties for treating rectangular clips as global tags
        tag.props.globalOrRectClip = tag.props.global or tag.type==ASSClipRect
        -- fill in missing friendly names
        tag.friendlyName = tag.friendlyName or tag.overrideName
        -- populate friendly name <-> tag name conversion tables
        if tag.friendlyName then
            self.toFriendlyName[name], self.toTagName[tag.friendlyName] = tag.friendlyName, name
        end
        -- fill tag names table
        local tagType = self.tagNames[tag.type]
        if not tagType then
            self.tagNames[tag.type] = {name, n=1}
        else
            tagType[tagType.n+1], tagType.n = name, tagType.n+1
        end
        -- fill override tag name -> internal tag name mapping tables
        if tag.overrideName then
            local ovrToName = self.tagNames[tag.overrideName]
            if ovrToName then
                ovrToName[#ovrToName+1] = name
            else self.tagNames[tag.overrideName] = {name} end
        end
        -- fill sort order table
        if tag.sort then
            self.tagSortOrder[tag.sort] = name
        end
    end

    self.tagSortOrder = table.reduce(self.tagSortOrder)

    -- make tag names table also work as a set
    for _,names in pairs(self.tagNames) do
        if not names.n then names.n = #names end
        for i=1,names.n do
            names[names[i]] = true
        end
    end

    self.classes = {
        lineSection = {ASSLineTextSection, ASSLineTagSection, ASSLineDrawingSection, ASSLineCommentSection},
        drawingCommandMappings = {
            m = ASSDrawMove,
            n = ASSDrawMoveNc,
            l = ASSDrawLine,
            b = ASSDrawBezier,
            c = ASSDrawClose
        }
    }
    self.classes.drawingCommands = table.values(self.classes.drawingCommandMappings)

    -- make classes table also work as a set
    for _,cls in pairs(self.classes) do
        if not cls.n then cls.n = #cls end
        for i=1,#cls do
            cls[cls[i]] = true
        end
    end

    self.cache = {ASSInspector = {}}

    self.defaults = {
        line = {actor="", class="dialogue", comment=false, effect="", start_time=0, end_time=5000, layer=0,
                margin_l=0, margin_r=0, margin_t=0, section="[Events]", style="Default", text="", extra={}}
    }

    return self
end

function ASSFoundation:getTagNames(ovrNames)
    if type(ovrNames)=="string" then
        if self.tagMap[ovrNames] then return name end
        ovrNames = {ovrNames}
    end

    local tagNames, t = {}, 1
    for i=1,#ovrNames do
        local ovrToTag = ASS.tagNames[ovrNames[i]]
        if ovrToTag and ovrToTag.n==1 then
            tagNames[t] = ovrToTag[1]
        elseif ovrToTag then
            tagNames, t = table.joinInto(tagNames, ovrToTag)
        elseif self.tagMap[ovrNames[i]] then
            tagNames[t] = ovrNames[i]
        end
        t=t+1
    end

    return tagNames
end

function ASSFoundation:mapTag(name)
    assertEx(type(name)=="string", "argument #1 must be a string, got a %s.", type(name))
    return assertEx(self.tagMap[name], "can't find tag %s", name)
end

function ASSFoundation:createTag(name, ...)
    local tag = self:mapTag(name)
    return tag.type{tagProps=tag.props, ...}
end

function ASSFoundation:createLine(args)
    local defaults, cnts, ref, newLine = self.defaults.line, args[1], args[2]

    local msg = "argument #2 (ref) must be a Line, LineCollection or %s object or nil; got a %s."
    if type(ref)=="table" then
        if ref.__class == Line then
            ref = ref.parentCollection
        elseif ref.class == ASSLineContents then
            ref = ref.line.parentCollection
        end
        assertEx(ref.__class==LineCollection, msg, ASSLineContents.typeName, ref.typeName or "table")
    elseif ref~=nil then
        error(string.format(msg, ASSLineContents.typeName, type(ref)))
    end

    msg = "argument #1 (contents) must be a Line or %s object, a section or a table of sections, a raw line or line string, or nil; got a %s."
    local msgNoRef = "can only create a Line with a reference to a LineCollection, but none could be found."
    if not cnts then
        assertEx(ref, msgNoRef)
        newLine = Line({}, ref, table.merge(defaults, args))
        newLine:parse()
    elseif type(cnts)=="string" then
        local p, s, num = {}, {cnts:match("^Dialogue: (%d+),(.-),(.-),(.-),(.-),(%d*),(%d*),(%d*),(.-),(.-)$")}, tonumber
        if #s == 0 then
            p = util.copy(defaults)
            p.text = cnts
        else
            p.layer, p.start_time, p.end_time, p.style = num(s[1]), util.timecode2ms(s[2]), util.timecode2ms(s[3]), s[4]
            p.actor, p.margin_l, p.margin_r, p.margin_t, p.effect, p.text = s[5], num(s[6]), num(s[7]), num(s[8]), s[9], s[10]
        end
        newLine = Line({}, assertEx(ref, msgNoRef), table.merge(defaults, p, args))
        ASS.parse(newLine)
    elseif type(cnts)~="table" then
        error(string.format(msg, ASSLineContents.typeName, type(cnts)))
    elseif cnts.__class==Line then
        -- Line objects will be copied and the ASSFoundation stuff committed and reparsed (full copy)
        local text = cnts.ASS and cnts.ASS:getString() or cnts.text
        newLine = Line(cnts, assertEx(ref or cnts.parentCollection, msgNoRef), args)
        newLine.text = text
        ASS.parse(newLine)
    elseif cnts.class==ASSLineContents then
        -- ASSLineContents object will be attached to the new line
        -- line properties other than the text will be taken either from the defaults or the current previous line
        ref = assertEx(ref or cnts.parentCollection, msgNoRef)
        newLine = useLineProps and Line(cnts.line, ref, args) or Line({}, ref, table.merge(defaults, args))
        newLine.ASS, cnts.ASS.line = cnts.ASS, newLine
        newLine:commit()
    else
        -- A new ASSLineContents object is created from the supplied sections and attached to a new Line
        if cnts.class then cnts = {cnts} end
        local secTypes = ASS.classes.lineSection
        newLine = Line({}, ref, table.merge(defaults, args))
        for i=1,#cnts do
            -- TODO: move into ASSLineContents:new()
            assertEx(ASS.instanceOf(cnts[i],secTypes), msg, ASSLineContents.typeName, cnts[i].typeName or type(cnts[i]))
            if not ref then
                local lc = self:getParentLineContents()
                ref = lc and lc.line.parentCollection
            end
        end
        assertEx(ref, msgNoRef)
        newLine.ASS = ASSLineContents(newLine, cnts)
        newLine.ASS:commit()
    end
    newLine:createRaw()
    return newLine
end

function ASSFoundation:getParentLineContents(obj)
    if not type(obj)=="table" and obj.class then return nil end
    while obj do
        if obj.class == ASSLineContents then
            return obj
        end
        obj = obj.parent
    end
    return nil
end

function ASSFoundation:getScriptInfo(obj)
    if type(obj)=="table" and obj.class then
        local lineContents = self:getParentLineContents(obj)
        return lineContents and lineContents.scriptInfo, lineContents
    end
    obj = default(obj, self.cache.lastSub)
    assertEx(obj and type(obj)=="userdata" and obj.insert,
             "can't get script info because no valid subtitles object was supplied or cached.")
    self.cache.lastSub = obj
    return util.getScriptInfo(obj)
end

function ASSFoundation:getTagFromString(str)
    for _,tag in pairs(self.tagMap) do
        if tag.pattern then
            local res = {str:find("^"..tag.pattern)}
            if #res>0 then
                local start, end_ = table.remove(res,1), table.remove(res,1)
                return tag.type{raw=res, tagProps=tag.props}, start, end_
            end
        end
    end
    local tagType = self.tagMap[str:sub(1,1)=="\\" and "unknown" or "junk"]
    return ASSUnknown{str, tagProps=tagType.props}, 1, #str
end

function ASSFoundation:getTagsNamesFromProps(props)
    local names, n = {}, 1
    for name,tag in pairs(self.tagMap) do
        if tag.props then
            local propMatch = true
            for k,v in pairs(props) do
                if tag.props[k]~=v or tag.props[k]==false and tag.props[k] then
                    propMatch = false
                    break
                end
            end
            if propMatch then
                names[n], n = name, n+1
            end
        end
    end
    return names
end

function ASSFoundation:formatTag(tagRef, ...)
    return self:mapTag(tagRef.__tag.name).format:formatFancy(...)
end

function ASSFoundation.instanceOf(val, classes, filter, includeCompatible)
    local clsSetObj = type(val)=="table" and val.instanceOf

    if not clsSetObj then
        return false
    elseif classes==nil then
        return table.keys(clsSetObj)[1], includeCompatible and table.keys(val.compatible)
    elseif type(classes)~="table" or classes.instanceOf then
        classes = {classes}
    end

    if type(filter)=="table" then
        if filter.instanceOf then
            filter={[filter]=true}
        elseif #filter>0 then
            filter = table.set(filter)
        end
    end
    for i=1,#classes do
        if (clsSetObj[classes[i]] or includeCompatible and val.compatible[classes[i]]) and (not filter or filter[classes[i]]) then
            return classes[i]
        end
    end
    return false
end

function ASSFoundation.parse(line)
    line.ASS = ASSLineContents(line)
    return line.ASS
end

ASS = ASSFoundation()

ASS.defaults.drawingTestTags = ASSLineTagSection{ASS:createTag("position",0,0), ASS:createTag("align",7),
                               ASS:createTag("outline", 0), ASS:createTag("scale_x", 100), ASS:createTag("scale_y", 100),
                               ASS:createTag("alpha", 0), ASS:createTag("angle", 0), ASS:createTag("shadow", 0)}