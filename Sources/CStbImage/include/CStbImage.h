// The PNG decoder the SDL front end loads its textures with. Just the
// declarations; the implementation is compiled once, in stb_image.c.
#define STBI_ONLY_PNG
#define STBI_NO_STDIO
#include "../stb_image.h"
