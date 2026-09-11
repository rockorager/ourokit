/*
 * Use upstream implementations without calling the broad library openers.
 * Including these pinned sources makes their private functions available to
 * this allowlist; do not also compile them as separate translation units.
 * In particular, luaopen_base exposes I/O and luaopen_math seeds an RNG.
 */
#include "lbaselib.c"
#include "lmathlib.c"
#include "lstrlib.c"
#include "loslib.c"

/* Lua's documented alternative to consulting OS entropy during table.sort. */
#define l_randomizePivot(L) (~0u)
#include "ltablib.c"
#include "lutf8lib.c"

/* Expose only the two clock functions, not luaopen_os or its process/filesystem API. */
int ouro_os_time(lua_State *L) {
    if (lua_gettop(L) != 0)
        return luaL_error(L, "ouro.time expects no arguments");
    return os_time(L);
}

int ouro_os_date(lua_State *L) {
    int arguments = lua_gettop(L);
    if ((arguments != 1 && arguments != 2) || lua_type(L, 1) != LUA_TSTRING)
        return luaL_error(L, "ouro.date expects a format and optional timestamp");
    return os_date(L);
}

static const luaL_Reg ouro_base[] = {
    {"assert", luaB_assert},
    {"error", luaB_error},
    {"ipairs", luaB_ipairs},
    {"next", luaB_next},
    {"pairs", luaB_pairs},
    {"pcall", luaB_pcall},
    {"select", luaB_select},
    {"tonumber", luaB_tonumber},
    {"tostring", luaB_tostring},
    {"type", luaB_type},
    {"xpcall", luaB_xpcall},
    {NULL, NULL},
};

static const luaL_Reg ouro_string[] = {
    {"byte", str_byte},
    {"char", str_char},
    {"find", str_find},
    {"format", str_format},
    {"gmatch", gmatch},
    {"gsub", str_gsub},
    {"len", str_len},
    {"lower", str_lower},
    {"match", str_match},
    {"rep", str_rep},
    {"reverse", str_reverse},
    {"sub", str_sub},
    {"upper", str_upper},
    {"pack", str_pack},
    {"packsize", str_packsize},
    {"unpack", str_unpack},
    {NULL, NULL},
};

static const luaL_Reg ouro_table[] = {
    {"concat", tconcat},
    {"create", tcreate},
    {"insert", tinsert},
    {"pack", tpack},
    {"unpack", tunpack},
    {"remove", tremove},
    {"move", tmove},
    {"sort", sort},
    {NULL, NULL},
};

static const luaL_Reg ouro_math[] = {
    {"abs", math_abs},
    {"acos", math_acos},
    {"asin", math_asin},
    {"atan", math_atan},
    {"ceil", math_ceil},
    {"cos", math_cos},
    {"deg", math_deg},
    {"exp", math_exp},
    {"tointeger", math_toint},
    {"floor", math_floor},
    {"fmod", math_fmod},
    {"frexp", math_frexp},
    {"ult", math_ult},
    {"ldexp", math_ldexp},
    {"log", math_log},
    {"max", math_max},
    {"min", math_min},
    {"modf", math_modf},
    {"rad", math_rad},
    {"sin", math_sin},
    {"sqrt", math_sqrt},
    {"tan", math_tan},
    {"type", math_type},
    {NULL, NULL},
};

static const luaL_Reg ouro_utf8[] = {
    {"offset", byteoffset},
    {"codepoint", codepoint},
    {"char", utfchar},
    {"len", utflen},
    {"codes", iter_codes},
    {NULL, NULL},
};

int ouro_open_safe_libraries(lua_State *L) {
    lua_pushglobaltable(L);
    luaL_setfuncs(L, ouro_base, 0);
    lua_pop(L, 1);

    luaL_newlib(L, ouro_string);
    createmetatable(L); /* String methods see only our allowlisted table. */
    lua_setglobal(L, "string");

    luaL_newlib(L, ouro_table);
    lua_setglobal(L, "table");

    luaL_newlib(L, ouro_math);
    lua_pushnumber(L, PI);
    lua_setfield(L, -2, "pi");
    lua_pushnumber(L, (lua_Number)HUGE_VAL);
    lua_setfield(L, -2, "huge");
    lua_pushinteger(L, LUA_MAXINTEGER);
    lua_setfield(L, -2, "maxinteger");
    lua_pushinteger(L, LUA_MININTEGER);
    lua_setfield(L, -2, "mininteger");
    lua_setglobal(L, "math");

    luaL_newlib(L, ouro_utf8);
    lua_pushlstring(L, UTF8PATT, sizeof(UTF8PATT) - 1);
    lua_setfield(L, -2, "charpattern");
    lua_setglobal(L, "utf8");
    return 0;
}
