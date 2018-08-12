describe("cookie module", function()
	local http_cookie = require "http.cookie"
	local http_headers = require "http.headers"
	describe(".parse_cookies", function()
		it("can parse a request with a single cookie headers", function()
			local h = http_headers.new()
			h:append("cookie", "foo=FOO; bar=BAR")
			assert.same({
				foo = "FOO";
				bar = "BAR";
			}, http_cookie.parse_cookies(h))
		end)
		it("can parse a request with a multiple cookie headers", function()
			local h = http_headers.new()
			h:append("cookie", "foo=FOO; bar=BAR")
			h:append("cookie", "baz=BAZ; bar=BAR2")
			h:append("cookie", "qux=QUX")
			assert.same({
				foo = "FOO";
				bar = "BAR2"; -- last occurence should win
				baz = "BAZ";
				qux = "QUX";
			}, http_cookie.parse_cookies(h))
		end)
	end)
	it(":get works", function()
		local s = http_cookie.new_store()
		assert.same(nil, s:get("mysite.com", "/", "lang"))
		local key, value, params = http_cookie.parse_setcookie("lang=en-US; Expires=Wed, 09 Jun 2021 10:18:14 GMT")
		assert(s:store("mysite.com", "/", true, true, nil, key, value, params))
		assert.same("en-US", s:get("mysite.com", "/", "lang"))
		assert.same(nil, s:get("other.com", "/", "lang"))
		assert.same(nil, s:get("mysite.com", "/other", "lang"))
		assert.same(nil, s:get("mysite.com", "/", "other"))
	end)
	describe("examples from spec", function()
		it("can handle basic cookie without parameters", function()
			local s = http_cookie.new_store()
			assert(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("SID=31d4d96e407aad42")))
			assert.same("SID=31d4d96e407aad42", s:lookup("example.com", "/", true, true))
			assert.same("SID=31d4d96e407aad42", s:lookup("example.com", "/other", true, true))
			assert.same("", s:lookup("subdomain.example.com", "/", true, true))
			assert.same("", s:lookup("other.com", "/", true, true))
		end)

		it("can handle cookie with Path and Domain parameters", function()
			local s = http_cookie.new_store()
			assert(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("SID=31d4d96e407aad42; Path=/; Domain=example.com")))
			assert.same("SID=31d4d96e407aad42", s:lookup("example.com", "/", true, true))
			assert.same("SID=31d4d96e407aad42", s:lookup("example.com", "/other", true, true))
			assert.same("SID=31d4d96e407aad42", s:lookup("subdomain.example.com", "/", true, true))
			assert.same("", s:lookup("other.com", "/", true, true))
		end)

		it("can handle two cookies with different names and parameters", function()
			local s = http_cookie.new_store()
			assert(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("SID=31d4d96e407aad42; Path=/; Secure; HttpOnly")))
			assert(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("lang=en-US; Path=/; Domain=example.com")))
			assert.same("SID=31d4d96e407aad42; lang=en-US", s:lookup("example.com", "/other", true, true))
			assert.same("lang=en-US", s:lookup("subdomain.example.com", "/", true, true))
			assert.same("lang=en-US", s:lookup("example.com", "/", true, false))
			assert.same("lang=en-US", s:lookup("example.com", "/", false, true))
			assert.same("", s:lookup("other.com", "/", true, true))
		end)

		it("can expire a cookie", function()
			local s = http_cookie.new_store()
			s.time = function() return 1234567890 end -- set time to something before the expiry
			-- in spec this is kept from previous example.
			assert(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("SID=31d4d96e407aad42; Path=/; Secure; HttpOnly")))
			assert(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("lang=en-US; Expires=Wed, 09 Jun 2021 10:18:14 GMT")))
			assert.same("SID=31d4d96e407aad42; lang=en-US", s:lookup("example.com", "/", true, true))
			s.time = function() return 9234567890 end -- set time to something after the expiry
			assert.same("SID=31d4d96e407aad42", s:lookup("example.com", "/", true, true))
		end)
	end)
	describe(":store uses correct domain", function()
		it("ignores leading '.' in domain", function()
			local s = http_cookie.new_store()
			assert.truthy(s:store("subdomain.example.com", "/", true, true, nil, http_cookie.parse_setcookie("foo=bar; Domain=.example.com")))
			assert.same("bar", s:get("example.com", "/", "foo"))
		end)
		;(http_cookie.store_methods.psl and it or pending)("checks against public suffix list", function()
			assert(not http_cookie.store_methods.psl:is_cookie_domain_acceptable("foo.com", "com"))
			local s = http_cookie.new_store()
			assert.falsy(s:store("foo.com", "/", true, true, nil, http_cookie.parse_setcookie("foo=bar; Domain=com")))
		end)
		;(http_cookie.store_methods.psl and it or pending)("allows explicit domains even when on the public suffix list", function()
			assert(http_cookie.store_methods.psl:is_public_suffix("hashbang.sh"))
			local s = http_cookie.new_store()
			assert.truthy(s:store("hashbang.sh", "/", true, true, nil, http_cookie.parse_setcookie("foo=bar; Domain=hashbang.sh")))
			-- And check that host_only flag has been set to true
			assert.same("foo=bar", s:lookup("hashbang.sh", "/", true, true))
			assert.same("", s:lookup("sub.hashbang.sh", "/", true, true))
		end)
		it("doesn't domain-match a completely different domain", function()
			local s = http_cookie.new_store()
			assert.falsy(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("foo=bar; Domain=other.example.com")))
		end)
		it("doesn't domain-match a subdomain when request is at super-domain", function()
			local s = http_cookie.new_store()
			assert.falsy(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("foo=bar; Domain=subdomain.example.com")))
		end)
		it("doesn't domain-match a partial ip", function()
			local s = http_cookie.new_store()
			assert.falsy(s:store("127.0.0.1", "/", true, true, nil, http_cookie.parse_setcookie("foo=bar; Domain=0.0.1")))
		end)
	end)
	describe("domain-match on lookup", function()
		it("matches domains correctly when host_only flag is true", function()
			local s = http_cookie.new_store()
			assert.truthy(s:store("s.example.com", "/", true, true, nil, http_cookie.parse_setcookie("foo=bar")))
			assert.same("bar", s:get("s.example.com", "/", "foo"))

			assert.same("foo=bar", s:lookup("s.example.com", "/", true, true))
			assert.same("", s:lookup("s.s.example.com", "/", true, true))
			assert.same("", s:lookup("s.s.s.example.com", "/", true, true))
			assert.same("", s:lookup("com", "/", true, true))
			assert.same("", s:lookup("example.com", "/", true, true))
			assert.same("", s:lookup("other.com", "/", true, true))
			assert.same("", s:lookup("s.other.com", "/", true, true))
		end)
		it("matches domains correctly when host_only flag is false", function()
			local s = http_cookie.new_store()
			assert.truthy(s:store("s.example.com", "/", true, true, nil, http_cookie.parse_setcookie("foo=bar; Domain=s.example.com")))
			assert.same("bar", s:get("s.example.com", "/", "foo"))

			assert.same("foo=bar", s:lookup("s.example.com", "/", true, true))
			assert.same("foo=bar", s:lookup("s.s.example.com", "/", true, true))
			assert.same("foo=bar", s:lookup("s.s.s.example.com", "/", true, true))
			assert.same("", s:lookup("com", "/", true, true))
			assert.same("", s:lookup("example.com", "/", true, true))
			assert.same("", s:lookup("other.com", "/", true, true))
			assert.same("", s:lookup("s.other.com", "/", true, true))
		end)
	end)
	describe(":store uses correct path", function()
		it("handles absolute set-cookie header", function()
			local s = http_cookie.new_store()
			assert.truthy(s:store("example.com", "/absolute/path", true, true, nil, http_cookie.parse_setcookie("foo=bar; Path=/different/absolute/path")))
			assert.same("bar", s:get("example.com", "/different/absolute/path", "foo"))
		end)
		it("handles relative set-cookie path", function()
			local s = http_cookie.new_store()
			assert.truthy(s:store("example.com", "/absolute/path", true, true, nil, http_cookie.parse_setcookie("foo=bar; Path=relative/path")))
			-- should trim off last component
			assert.same("bar", s:get("example.com", "/absolute", "foo"))
		end)
		it("handles relative set-cookie path with no request path", function()
			local s = http_cookie.new_store()
			assert.truthy(s:store("example.com", "?", true, true, nil, http_cookie.parse_setcookie("foo=bar; Path=relative/path")))
			-- should default to /
			assert.same("bar", s:get("example.com", "/", "foo"))
		end)
		it("handles absolute set-cookie path with relative request path", function()
			local s = http_cookie.new_store()
			assert.truthy(s:store("example.com", "relative/path", true, true, nil, http_cookie.parse_setcookie("foo=bar; Path=/absolute/path")))
			assert.same("bar", s:get("example.com", "/absolute/path", "foo"))
		end)
		it("handles relative request path and relative set-cookie header", function()
			local s = http_cookie.new_store()
			assert.truthy(s:store("example.com", "relative/path", true, true, nil, http_cookie.parse_setcookie("foo=bar; Path=different/relative/path")))
			assert.same("bar", s:get("example.com", "/", "foo"))
		end)
	end)
	it("matches paths correctly", function()
		local s = http_cookie.new_store()
		assert.truthy(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("foo=bar; Path=/path/subpath")))
		assert.same("foo=bar", s:lookup("example.com", "/path/subpath/foo", true, true))
		assert.same("foo=bar", s:lookup("example.com", "/path/subpath/bar", true, true))
		assert.same("foo=bar", s:lookup("example.com", "/path/subpath", true, true))
		assert.same("", s:lookup("example.com", "/", true, true))
		assert.same("", s:lookup("example.com", "/path", true, true))
		assert.same("", s:lookup("example.com", "/path/otherpath/", true, true))
		assert.same("", s:lookup("example.com", "/path/otherpath/things", true, true))
	end)
	it("prefers max-age over expires", function()
		local s = http_cookie.new_store()
		assert(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("foo=bar; max-age=50; Expires=Thu, 01 Jan 1970 00:00:00 GMT")))
		assert.truthy(s:get("example.com", "/", "foo"))
		assert(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("foo=bar; max-age=0; Expires=Tue, 19 Jan 2038 03:14:07 GMT")))
		assert.falsy(s:get("example.com", "/", "foo"))
	end)
	it("supports HttpOnly attribute", function()
		local s = http_cookie.new_store()
		assert.falsy(s:store("example.com", "/", false, true, nil, http_cookie.parse_setcookie("foo=bar; HttpOnly")))
		assert.truthy(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("foo=bar; HttpOnly")))
		assert.same("", s:lookup("example.com", "/", false, true))
		assert.same("foo=bar", s:lookup("example.com", "/", true, true))
		-- Now try and overwrite it with non-http :store
		assert.falsy(s:store("example.com", "/", false, true, nil, http_cookie.parse_setcookie("foo=bar")))
	end)
	it("supports Secure attribute", function()
		local s = http_cookie.new_store()
		assert.falsy(s:store("example.com", "/", true, false, nil, http_cookie.parse_setcookie("foo=bar; Secure")))
		assert.truthy(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("foo=bar; Secure")))
		assert.same("", s:lookup("example.com", "/", true, false))
		assert.same("foo=bar", s:lookup("example.com", "/", true, true))
	end)
	describe("tough cookies", function()
		it("enforces __Secure- prefix", function()
			local s = http_cookie.new_store()
			assert.falsy(s:store("example.com", "/", true, false, nil, http_cookie.parse_setcookie("__Secure-foo=bar; Secure")))
			assert.falsy(s:store("example.com", "/", true, false, nil, http_cookie.parse_setcookie("__Secure-foo=bar")))
			assert.falsy(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("__Secure-foo=bar;")))
			assert.truthy(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("__Secure-foo=bar; Secure")))
		end)
		it("enforces __Host- prefix", function()
			local s = http_cookie.new_store()
			-- Checks secure flag
			assert.falsy(s:store("example.com", "/", true, false, nil, http_cookie.parse_setcookie("__Host-foo=bar; Secure")))
			assert.falsy(s:store("example.com", "/", true, false, nil, http_cookie.parse_setcookie("__Host-foo=bar")))
			assert.falsy(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("__Host-foo=bar;")))
			-- Checks for host only flag
			assert.falsy(s:store("sub.example.com", "/", true, true, nil, http_cookie.parse_setcookie("__Host-foo=bar; Secure; Domain=example.com")))
			-- Checks that path is /
			assert.falsy(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("__Host-foo=bar; Secure; Path=/path")))
			-- Success case
			assert.truthy(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("__Host-foo=bar; Secure")))
		end)
	end)
	describe("cookie fixing mitigation", function()
		it("ignores already existing path", function()
			local s = http_cookie.new_store()
			assert.truthy(s:store("example.com", "/path/subpath/foo", true, true, nil, http_cookie.parse_setcookie("foo=bar; Path=/path; Secure")))
			assert.falsy(s:store("example.com", "/path/subpath/foo", true, false, nil, http_cookie.parse_setcookie("foo=bar; Path=/path")))
		end)
	end)
	describe("SameSite attribute", function()
		it("fails to store if domain and site_for_cookies don't match", function()
			local s = http_cookie.new_store()
			assert.falsy(s:store("example.com", "/", true, true, "other.com", http_cookie.parse_setcookie("foo=foo; SameSite=Strict")))
		end)

		it("implements SameSite=Strict", function()
			local s = http_cookie.new_store()
			assert(s:store("example.com", "/", true, true, "example.com", http_cookie.parse_setcookie("foo=foo; SameSite=Strict")))
			assert.same("foo=foo", s:lookup("example.com", "/", true, true, true, "example.com"))
			assert.same("", s:lookup("example.com", "/", true, true, true, "other.com"))
		end)

		it("implements SameSite=Lax", function()
			local s = http_cookie.new_store()
			assert(s:store("example.com", "/", true, true, "example.com", http_cookie.parse_setcookie("foo=foo; SameSite=Lax")))
			assert.same("foo=foo", s:lookup("example.com", "/", true, true, true, "example.com", true))
			assert.same("foo=foo", s:lookup("example.com", "/", true, true, true, "other.com", true))
			assert.same("", s:lookup("example.com", "/", true, true, false, "other.com", true))
			assert.same("", s:lookup("example.com", "/", true, true, true, "other.com", false))
			assert.same("", s:lookup("example.com", "/", true, true, false, "other.com", false))
		end)
	end)
	it("cleans up", function()
		local s = http_cookie.new_store()
		assert.truthy(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("foo=foo; Expires=Wed, 09 Jun 2021 10:18:14 GMT")))
		assert.same("foo", s:get("example.com", "/", "foo"))
		s.time = function() return 9876543210 end -- set time to something after the expiry
		s:clean()
		assert.same(nil, s:get("example.com", "/", "foo"))
	end)
	describe(":remove()", function()
		it("can remove cookies by domain", function()
			local s = http_cookie.new_store()
			-- Try remove on empty store
			s:remove("example.com")

			assert.truthy(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("foo=foo")))
			assert.truthy(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("foo=other; Path=/subpath")))
			assert.truthy(s:store("other.com", "/", true, true, nil, http_cookie.parse_setcookie("bar=bar")))
			assert.same("foo", s:get("example.com", "/", "foo"))
			assert.same("other", s:get("example.com", "/subpath", "foo"))
			assert.same("bar", s:get("other.com", "/", "bar"))

			s:remove("example.com")
			assert.same(nil, s:get("example.com", "/", "foo"))
			assert.same(nil, s:get("example.com", "/subpath", "foo"))
			assert.same("bar", s:get("other.com", "/", "bar"))
		end)
		it("can remove cookies by path", function()
			local s = http_cookie.new_store()
			-- Try remove on empty store
			s:remove("example.com", "/")

			assert.truthy(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("foo=foo")))
			assert.truthy(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("foo=other; Path=/subpath")))
			assert.truthy(s:store("other.com", "/", true, true, nil, http_cookie.parse_setcookie("bar=bar")))
			assert.truthy(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("qux=qux")))
			assert.same("foo", s:get("example.com", "/", "foo"))
			assert.same("other", s:get("example.com", "/subpath", "foo"))
			assert.same("bar", s:get("other.com", "/", "bar"))
			assert.same("qux", s:get("example.com", "/", "qux"))

			-- Remove all names under "/" path
			s:remove("example.com", "/")
			assert.same(nil, s:get("example.com", "/", "foo"))
			assert.same("other", s:get("example.com", "/subpath", "foo"))
			assert.same("bar", s:get("other.com", "/", "bar"))
			assert.same(nil, s:get("example.com", "/", "qux"))

			-- Remove last path in domain (making domain empty)
			s:remove("example.com", "/subpath")
			assert.same(nil, s:get("example.com", "/", "foo"))
			assert.same(nil, s:get("example.com", "/subpath", "foo"))
			assert.same("bar", s:get("other.com", "/", "bar"))
			assert.same(nil, s:get("example.com", "/", "qux"))
		end)
		it("can remove cookies by name", function()
			local s = http_cookie.new_store()
			-- Try remove on empty store
			s:remove("example.com", "/", "foo")

			assert.truthy(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("foo=foo")))
			assert.truthy(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("foo=other; Path=/subpath")))
			assert.truthy(s:store("other.com", "/", true, true, nil, http_cookie.parse_setcookie("bar=bar")))
			assert.truthy(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("qux=qux")))
			assert.same("foo", s:get("example.com", "/", "foo"))
			assert.same("other", s:get("example.com", "/subpath", "foo"))
			assert.same("bar", s:get("other.com", "/", "bar"))
			assert.same("qux", s:get("example.com", "/", "qux"))

			-- Remove just one name
			s:remove("example.com", "/", "foo")
			assert.same(nil, s:get("example.com", "/", "foo"))
			assert.same("other", s:get("example.com", "/subpath", "foo"))
			assert.same("bar", s:get("other.com", "/", "bar"))
			assert.same("qux", s:get("example.com", "/", "qux"))

			-- Remove last name in path (making path empty)
			s:remove("example.com", "/", "qux")
			assert.same(nil, s:get("example.com", "/", "foo"))
			assert.same("other", s:get("example.com", "/subpath", "foo"))
			assert.same("bar", s:get("other.com", "/", "bar"))
			assert.same(nil, s:get("example.com", "/", "qux"))

			-- Remove last name in domain (making domain empty)
			s:remove("example.com", "/subpath", "foo")
			assert.same(nil, s:get("example.com", "/", "foo"))
			assert.same(nil, s:get("example.com", "/subpath", "foo"))
			assert.same("bar", s:get("other.com", "/", "bar"))
			assert.same(nil, s:get("example.com", "/", "qux"))
		end)
	end)
	describe("cookie order", function()
		it("returns in order for simple cookies", function() -- used as assumed base case for future tests in this section
			local s = http_cookie.new_store()
			assert(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("foo=basic")))
			assert(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("bar=basic")))
			assert.same("bar=basic; foo=basic", s:lookup("example.com", "/", true, true))
		end)
		it("returns in order for domain differing cookies", function() -- spec doesn't care about this case
			local s = http_cookie.new_store()
			assert(s:store("sub.example.com", "/", true, true, nil, http_cookie.parse_setcookie("foo=domain; Domain=sub.example.com")))
			assert(s:store("sub.example.com", "/", true, true, nil, http_cookie.parse_setcookie("bar=domain; Domain=example.com")))
			assert.same("bar=domain; foo=domain", s:lookup("sub.example.com", "/", true, true))
		end)
		it("returns in order for different length paths", function()
			local s = http_cookie.new_store()
			assert(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("foo=path; Path=/path/longerpath")))
			assert(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("bar=path; Path=/path/")))
			assert.same("foo=path; bar=path", s:lookup("example.com", "/path/longerpath", true, true))
		end)
		it("returns in order for different creation times", function()
			local s = http_cookie.new_store()
			s.time = function() return 0 end
			assert(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("foo=time")))
			s.time = function() return 50 end
			assert(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("bar=time")))
			assert.same("foo=time; bar=time", s:lookup("example.com", "/path/longerpath", true, true))
		end)
		it("returns in order when all together!", function()
			local s = http_cookie.new_store()
			assert(s:store("sub.example.com", "/", true, true, nil, http_cookie.parse_setcookie("foo=basic")))
			assert(s:store("sub.example.com", "/", true, true, nil, http_cookie.parse_setcookie("bar=basic")))
			assert(s:store("sub.example.com", "/", true, true, nil, http_cookie.parse_setcookie("foo=path; Path=/path/longerpath")))
			assert(s:store("sub.example.com", "/", true, true, nil, http_cookie.parse_setcookie("bar=path; Path=/path/")))
			-- foo=domain case would get overridden below
			assert(s:store("sub.example.com", "/", true, true, nil, http_cookie.parse_setcookie("bar=domain; Domain=example.com")))
			s.time = function() return 0 end
			assert(s:store("sub.example.com", "/", true, true, nil, http_cookie.parse_setcookie("foo=time")))
			s.time = function() return 50 end
			assert(s:store("sub.example.com", "/", true, true, nil, http_cookie.parse_setcookie("bar=time")))
			assert.same("foo=path; bar=path; bar=domain; bar=time; foo=time", s:lookup("sub.example.com", "/path/longerpath", true, true))
		end)
	end)
	it("enforces store.max_cookie_length", function()
		local s = http_cookie.new_store()
		s.max_cookie_length = 3
		assert.falsy(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("foo=foo")))
		s.max_cookie_length = 8
		assert.truthy(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("foo=foo")))
		assert.falsy(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("bar=longervalue")))
	end)
	it("enforces store.max_cookies", function()
		local s = http_cookie.new_store()
		s.max_cookies = 0
		assert.falsy(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("foo=foo")))
		s.max_cookies = 1
		assert.truthy(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("foo=foo")))
		assert.falsy(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("bar=bar")))
		s:remove("example.com", "/", "foo")
		assert.truthy(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("bar=bar")))
	end)
	it("enforces store.max_cookies_per_domain", function()
		local s = http_cookie.new_store()
		s.max_cookies_per_domain = 0
		assert.falsy(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("foo=foo")))
		s.max_cookies_per_domain = 1
		assert.truthy(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("foo=foo")))
		assert.falsy(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("bar=bar")))
		assert.truthy(s:store("other.com", "/", true, true, nil, http_cookie.parse_setcookie("baz=baz")))
		s:remove("example.com", "/", "foo")
		assert.truthy(s:store("example.com", "/", true, true, nil, http_cookie.parse_setcookie("bar=bar")))
	end)
	it("can bake cookies", function()
		assert.same("foo=bar", http_cookie.bake("foo", "bar"))
		assert.same("foo=bar; Max-Age=0", http_cookie.bake("foo", "bar", -math.huge))
		assert.same("foo=bar; Expires=Thu, 01 Jan 1970 00:00:00 GMT", http_cookie.bake("foo", "bar", 0))
		assert.same("foo=bar; Max-Age=0; Domain=example.com; Path=/path; Secure; HttpOnly; SameSite=Strict",
			http_cookie.bake("foo", "bar", -math.huge, "example.com", "/path", true, true, "strict"))
		assert.same("foo=bar; Max-Age=0; Domain=example.com; Path=/path; Secure; HttpOnly; SameSite=Lax",
			http_cookie.bake("foo", "bar", -math.huge, "example.com", "/path", true, true, "lax"))
		assert.has.errors(function()
			http_cookie.bake("foo", "bar", -math.huge, "example.com", "/path", true, true, "somethingelse")
		end, [[invalid value for same_site, expected "strict" or "lax"]])
	end)
	it("can dump a netscape format cookiejar", function()
		local s = http_cookie.new_store()
		assert(s:store("example.com", "/", true, true, "example.com", http_cookie.parse_setcookie("foo=FOO;")))
		assert(s:store("example.com", "/", true, true, "example.com", http_cookie.parse_setcookie("bar=BAR; HttpOnly")))
		assert(s:store("example.com", "/", true, true, "example.com", http_cookie.parse_setcookie("baz=BAZ; Path=/someplace")))
		assert(s:store("sub.example.com", "/", true, true, "sub.example.com", http_cookie.parse_setcookie("subdomain=matched; Domain=sub.example.com")))
		assert(s:store("example.com", "/", true, true, "example.com", http_cookie.parse_setcookie("qux=QUX; SameSite=Lax")))
		assert(s:store("other.com", "/", true, true, "other.com", http_cookie.parse_setcookie("foo=somethingelse; HttpOnly")))
		local file = io.tmpfile()
		assert(s:save_to_file(file))
		assert(file:seek("set"))
		-- preamble
		assert.truthy(assert(file:read("*l")):match"^#.*HTTP Cookie File")
		assert.truthy(assert(file:read("*l")):match"^#")
		assert.same("", assert(file:read("*l")))
		local lines = {}
		for line in file:lines() do
			table.insert(lines, line)
		end
		table.sort(lines)
		assert.same({
			"#HttpOnly_example.com	TRUE	/	FALSE	2147483647	bar	BAR";
			"#HttpOnly_other.com	TRUE	/	FALSE	2147483647	foo	somethingelse";
			"example.com	TRUE	/	FALSE	2147483647	foo	FOO";
			"example.com	TRUE	/	FALSE	2147483647	qux	QUX";
			"example.com	TRUE	/someplace	FALSE	2147483647	baz	BAZ";
			"sub.example.com	FALSE	/	FALSE	2147483647	subdomain	matched";
		}, lines)
	end)
	it("can load a netscape format cookiejar", function()
		local s = http_cookie.new_store()
		local file = io.tmpfile()
		assert(file:write([[
# Netscape HTTP Cookie File
# https://curl.haxx.se/docs/http-cookies.html
# This file was generated by libcurl! Edit at your own risk.

#HttpOnly_other.com	TRUE	/	FALSE	2147483647	foo	somethingelse
sub.example.com	FALSE	/	FALSE	2147483647	subdomain	matched
example.com	TRUE	/	TRUE	2147483647	qux	QUX
#HttpOnly_example.com	TRUE	/	FALSE	2147483647	bar	BAR
example.com	TRUE	/	FALSE	2147483647	foo	FOO
example.com	TRUE	/someplace	FALSE	2147483647	baz	BAZ
]]))
		assert(file:seek("set"))
		assert(s:load_from_file(file))
		assert.same("bar=BAR; foo=FOO; qux=QUX", s:lookup("example.com", "/", true, true))
	end)
	it("can load a netscape format cookiejar with invalid lines", function()
		local s = http_cookie.new_store()
		local file = io.tmpfile()
		assert(file:write([[
example.com	TRUE	/	TRUE	2147483647	qux	QUX
not a valid line
example.com	INVALID_BOOLEAN	/	FALSE	2147483647	should	fail
example.com	TRUE	/	INVALID_BOOLEAN	2147483647	should	fail
example.com	TRUE	/	FALSE	not_a_number	should	fail
#HttpOnly_example.com	TRUE	/	FALSE	2147483647	bar	BAR
example.com	TRUE	/	FALSE	2147483647	foo	FOO
]]))
		assert(file:seek("set"))
		assert(s:load_from_file(file))
		assert.same("bar=BAR; foo=FOO; qux=QUX", s:lookup("example.com", "/", true, true))
	end)
end)
