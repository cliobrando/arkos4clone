/* Link-time stand-in for librga.so.2. The image ships the real library
 * (christianhaitian/linux-rga); this only gives the linker its SONAME and
 * the entry points libgo2 calls. Never installed or run. */
int c_RkRgaInit(void) { return 0; }
void c_RkRgaDeInit(void) { }
int c_RkRgaBlit(void *src, void *dst, void *src1) { return 0; }
int c_RkRgaColorFill(void *dst) { return 0; }
