local http_patts = require "lpeg_patterns.http"
local util = require "http.util"
local lpeg = require "lpeg"
local psl = require "psl"

local Set_Cookie_anchored = http_patts.Set_Cookie * lpeg.P(-1)

local function parse_set_cookie(text_cookie, host, path, time)
	assert(time, "missing time value for cookie parsing")
	local key, value, matched_cookie = Set_Cookie_anchored:match(text_cookie)
	if not key then
		return nil, "cookie did not properly parse"
	end
	local cookie = {
		creation = time;
		last_access = time;
		persistent = not not (matched_cookie.expires or matched_cookie["max-age"]);
		domain = matched_cookie.domain or host;
		path = matched_cookie.path or path;
		secure = matched_cookie.secure or false;
		http_only = matched_cookie.httponly or false;
		key = key;
		value = value;
		host_only = not not matched_cookie.domain;
		same_site = matched_cookie.same_site;
		expires = nil; -- preallocate for usage later
	}
	local age = matched_cookie["max-age"]
	if age then
		local is_negative, match = age:match("^(%-?)(%d+)$")
		if is_negative ~= "" then
			-- RFC 6265 section 5.2.2 - if the value when converted to an
			-- integer is negative, the expiration should be the earliest
			-- representable expiration time.
			cookie.expires = 0
		elseif not match then
			return nil, "expected [-]DIGIT* for max-age field"
		else
			cookie.expires = time + tonumber(match, 10)
		end
	else -- luacheck: ignore
		-- ::TODO:: make use of `expires` cookie value
	end
	return cookie
end

local function bake_cookie(data)
	assert(type(data.key) == "string", "`key` field for cookie must be string")
	assert(type(data.value) == "string", "`value` field for cookie must be string")
	local cookie = {data.key .. "=" .. data.value}
	if data.expires then
		cookie[#cookie + 1] = "; Expires=" .. util.imf_date(data.expires)
	end
	if data.max_age then
		cookie[#cookie + 1] = "; Max-Age=" .. string.format("%d", data.max_age)
	end
	if data.domain then
		cookie[#cookie + 1] = "; Domain=" .. data.domain
	end
	if data.path then
		cookie[#cookie + 1] = "; Path=" .. util.encodeURI(data.path)
	end
	if data.secure then
		cookie[#cookie + 1] = "; Secure"
	end
	if data.http_only then
		cookie[#cookie + 1] = "; HttpOnly"
	end
	-- This component is not a part of the RFC 6265 specification for the
	-- headers, but is instead from a draft of another RFC that builds on the
	-- original one.
	-- https://tools.ietf.org/html/draft-ietf-httpbis-cookie-same-site-00#section-4.1
	if data.same_site then
		local v
		if data.same_site:lower() == "strict" then
			v = "; SameSite=Strict"
		elseif data.same_site:lower() == "lax" then
			v = "; SameSite=Lax"
		else
			error('invalid value for same_site, expected "Strict" or "Lax"')
		end
		cookie[#cookie + 1] = v
	end
	return table.concat(cookie)
end

local Cookie_anchored = http_patts.Cookie * lpeg.P(-1)

local function match_cookies(cookie)
	local match = Cookie_anchored:match(cookie)
	if match then
		return match
	else
		return nil, "improper Cookie header format"
	end
end

local function parse_cookies(cookie)
	local cookies = match_cookies(cookie)
	local to_add = {}
	for k, v in pairs(cookies) do
		to_add[#to_add + 1] = {k, v}
	end
	local len = #cookies
	for i, v in ipairs(to_add) do
		cookies[len + i] = v
	end
	table.sort(cookies, function(t1, t2)
		return t1[1] < t2[1]
	end)
	return cookies
end

local cookiejar_methods = {}
if psl.latest then
	cookiejar_methods.psl_object = psl.latest()
else
	-- older versions of libpsl do not offer a `latest` list
	cookiejar_methods.psl_object = psl.builtin()
end
local cookiejar_mt = {
	__name = "http.cookies.cookiejar";
	__index = cookiejar_methods;
}

local function new_cookiejar()
	return setmetatable({cookies={}}, cookiejar_mt)
end

function cookiejar_methods:add(cookie, time)
	cookie.last_access = time or os.time()
	local domain, path, key = cookie.domain, cookie.path, cookie.key
	local cookies = self.cookies
	if cookies[domain] and cookies[domain][path] then
		local old_cookie = cookies[domain][path][key]
		if old_cookie then
			cookie.creation = old_cookie.creation
		end
	end

	local old_cookie = self:get(cookie.domain, cookie.path, cookie.key)
	if old_cookie then
		self:remove_cookie(old_cookie)
	end
	if cookie.persistent then
		local cookie_exp_time = cookie.expires
		local inserted = false
		for i=1, #cookies do
			-- insert into first spot where cookie expires after
			if cookies[i].expires < cookie_exp_time then
				inserted = true
				table.insert(cookies, i, cookie)
			end
		end
		if not inserted then
			cookies[#cookies + 1] = cookie
		end
	else
		cookie.expires = math.huge
		table.insert(cookies, 1, cookie)
	end

	local by_domain = cookies[domain]
	if not by_domain then
		by_domain = {}
		cookies[domain] = by_domain
	end
	local by_path = by_domain[path]
	if not by_path then
		by_path = {}
		by_domain[path] = by_path
	end
	by_path[key] = cookie
	return true
end

function cookiejar_methods:get(domain, path, key)
	local by_domain = self.cookies[domain]
	if not by_domain then
		return nil
	end
	local by_path = by_domain[path]
	if not by_path then
		return nil
	end
	return by_path[key]
end

function cookiejar_methods:remove_cookie(cookie)
	local cookies = self.cookies
	for i=1, #cookies do
		if cookie == cookies[i] then
			table.remove(cookies, i)
			cookies[cookie.domain][cookie.path][cookie.key] = nil
			return true
		end
	end
	return false
end

function cookiejar_methods:remove_cookies(cookies)
	local cookie_hashes = {}
	for _, key in pairs(cookies) do
		cookie_hashes[key] = true
	end
	local s_cookies = self.cookies
	local n = #s_cookies
	local start_hole = 0
	for i=1, n do
		local value = s_cookies[i]
		if value and cookie_hashes[value] then
			s_cookies[i] = nil
			local by_domain = s_cookies[value.domain]
			local by_path = by_domain[value.path]
			by_path[value.key] = nil
			if not next(by_path) then
				by_domain[value.path] = nil
				if not next(by_domain) then
					s_cookies[value.domain] = nil
				end
			end
			if start_hole == 0 then
				-- start_hole hasn't been initialized, and a hole exists, so
				-- start the hole at the current position
				start_hole = i
			end
		elseif start_hole ~= 0 then
			-- a cookie exists and isn't being removed, so shift the cookie
			-- downwards to the start of the hole
			s_cookies[start_hole] = value
			s_cookies[i] = nil
			start_hole = start_hole + 1
		end
	end
end

local function get_expired(jar, time)
	time = time or os.time()
	local cookies = jar.cookies
	local returned_cookies = {}
	for i=#cookies, 1, -1 do
		local cookie = cookies[i]
		if cookie.expires > time then
			break
		end
		returned_cookies[#returned_cookies + 1] = cookie
	end
	return returned_cookies
end

function cookiejar_methods:remove_expired(time)
	self:remove_cookies(get_expired(self, time))
end

function cookiejar_methods:trim(size)
	self:remove_expired()
	local cookies = self.cookies
	if #cookies > size then
		for i=#cookies, size + 1, -1 do
			local cookie = cookies[i]
			cookies[i] = nil
			local by_domain = cookies[cookie.domain]
			local by_path = by_domain[cookie.path]
			by_path[cookie.key] = nil
			if not next(by_path) then
				by_domain[cookie.path] = nil
				if not next(by_domain) then
					cookies[cookie.domain] = nil
				end
			end
		end
	end
end

local function serialize_cookies(cookies)
	local out_values = {}
	for _, cookie in pairs(cookies) do
		out_values[#out_values + 1] = cookie.key .. "=" .. cookie.value
	end
	return table.concat(out_values, "; ")
end

function cookiejar_methods:serialize_cookies_for(domain, path, secure)
	-- explicitly check for secure; the other two will fail if given bad args
	assert(type(secure) == "boolean", "expected boolean for `secure`")

	-- clear out expired cookies
	self:remove_expired()

	-- return empty table if no cookies are found
	if not self.cookies[domain] then
		return {}
	end

	-- check all paths and flatten into a list of sets
	local sets = {}
	for stored, set in pairs(self.cookies[domain]) do
		if stored:sub(1, #path) == path then
			for _, cookie in pairs(set) do
				sets[#sets + 1] = cookie
			end
		end
	end

	-- sort as per RFC 6265 section 5.4 part 2; while it's not needed, it will
	-- help with tests where values need to be reproducible
	table.sort(sets, function(x, y)
		if #x.path == #y.path then
			return x.creation < y.creation
		else
			return #x.path > #y.path
		end
	end)

	-- populate cookie list
	local cookies = {}
	for _, cookie in pairs(sets) do
		if not cookie.host_only then
			if self.psl_object:is_cookie_domain_acceptable(domain, cookie.domain) then
				local is_cookie_secure = cookie.secure
				if is_cookie_secure and secure or not is_cookie_secure then
					cookies[#cookies + 1] = cookie
				end
			end
		elseif cookie.domain == domain then
			local is_cookie_secure = cookie.secure
			if is_cookie_secure and secure or not is_cookie_secure then
				cookies[#cookies + 1] = cookie
			end
		end
	end

	-- update access time for each cookie
	local time = os.time()
	for _, cookie in pairs(cookies) do
		cookie.last_access = time
	end

	return serialize_cookies(cookies)
end

return {
	match_cookies = match_cookies;
	parse_set_cookie = parse_set_cookie;
	bake_cookie = bake_cookie;
	parse_cookies = parse_cookies;
	serialize_cookies = serialize_cookies;
	cookiejar = {
		new = new_cookiejar;
		methods = cookiejar_methods;
		mt = cookiejar_mt;
	};
}
