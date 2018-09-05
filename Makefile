OPENRESTY_INSTALL_DIR ?= /usr/local/openresty

.PHONY: all luacheck test install

all: ;

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

	sudo cp lib/resty/*.lua $(OPENRESTY_INSTALL_DIR)/lualib/resty
	sudo cp -r lib/resty/http2/ $(OPENRESTY_INSTALL_DIR)/lualib/resty/
	prove -I../test-nginx/lib -r -s t/
