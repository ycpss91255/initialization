-- Pure-lua Dockerfile syntax highlighter.
-- Handles Dockerfile variants (Dockerfile.dev, foo.dockerfile, ...) whose
-- filenames syntect's bundled Dockerfile syntax does not recognize.

local M = {}

local KEYWORDS = {
	FROM = true, RUN = true, CMD = true, LABEL = true, MAINTAINER = true,
	EXPOSE = true, ENV = true, ADD = true, COPY = true, ENTRYPOINT = true,
	VOLUME = true, USER = true, WORKDIR = true, ARG = true, ONBUILD = true,
	STOPSIGNAL = true, HEALTHCHECK = true, SHELL = true,
}

local function highlight(line)
	local indent, content = line:match("^(%s*)(.*)$")
	if content == "" then
		return ui.Line(line)
	end
	if content:sub(1, 1) == "#" then
		return ui.Line(line):style(ui.Style():fg("darkgray"))
	end

	local kw = content:match("^([A-Za-z]+)")
	if kw and KEYWORDS[kw:upper()] then
		local rest = content:sub(#kw + 1)
		return ui.Line({
			ui.Span(indent),
			ui.Span(kw):style(ui.Style():fg("magenta"):bold()),
			ui.Span(rest),
		})
	end

	return ui.Line(line)
end

function M:peek(job)
	local path = tostring(job.file.url)
	local f, err = io.open(path, "r")
	if not f then
		return ya.preview_widget(job, ui.Text("Cannot open: " .. tostring(err)):area(job.area))
	end

	local skip = job.skip or 0
	local limit = job.area.h
	local lines, i = {}, 0
	for line in f:lines() do
		i = i + 1
		if i > skip then
			lines[#lines + 1] = highlight(line:gsub("\t", "  "))
			if #lines >= limit then break end
		end
	end
	f:close()

	ya.preview_widget(job, ui.Text(lines):area(job.area))
end

function M:seek(job)
	local h = cx.active.current.hovered
	if h and h.url == job.file.url then
		local step = math.floor(job.units * job.area.h / 10)
		ya.emit("peek", {
			math.max(0, cx.active.preview.skip + step),
			only_if = job.file.url,
		})
	end
end

return M
