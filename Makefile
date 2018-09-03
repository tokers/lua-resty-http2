OPENRESTY_PREFIX=/usr/local/openresty

PREFIX ?=          /usr/local
LUA_INCLUDE_DIR ?= $(PREFIX)/include
LUA_LIB_DIR ?=     $(PREFIX)/lib/lua/$(LUA_VERSION)
INSTALL ?= install

.PHONY: all luacheck test install

all: ;

install: all
	$(INSTALL) -d $(DESTDIR)/$(LUA_LIB_DIR)/resty/
	$(INSTALL) lib/resty/*.lua $(DESTDIR)/$(LUA_LIB_DIR)/resty/

luacheck:
	luacheck --std ngx_lua lib/resty/http2.lua lib/resty/http2/*.lua
	@echo ""

luareleng:
	util/lua-releng
	@echo ""

test: luareleng luacheck
	@echo -n "resty t/unit/test_hpack.lua ...... "
	@resty t/unit/test_hpack.lua
	@echo "ok"
	@resty t/unit/test_huffman.lua
	@echo -n "resty t/unit/test_hufman.lua ...... "
	@resty t/unit/test_hpack.lua
	@echo -e "ok\n"

	sudo cp lib/resty/*.lua $(OPENRESTY_PREFIX)/lualib/resty
	sudo cp -r lib/resty/http2/ $(OPENRESTY_PREFIX)/lualib/resty/
	PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$$PATH prove -I../test-nginx/lib -r -s t/
