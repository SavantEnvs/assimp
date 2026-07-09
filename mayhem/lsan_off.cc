// Disables LeakSanitizer at build time (ASan and UBSan stay fully active).
extern "C" int __lsan_is_turned_off() { return 1; }
