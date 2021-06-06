#include <stdio.h>
#include <stdlib.h>

#include "common.h"
#include "string.h"
#include "strstuff.h"


str readFile(const char* filename) {
  str out = {
    .len = 0,
    .bytes = NULL
  };
  FILE* fp; {
    fp = fopen(filename, "r");
    if (fp == NULL) { return out; }
  }
  size_t fileSize; {
    fseek(fp, 0, SEEK_END);
    fileSize = ftell(fp);
    rewind(fp);
  }
  { // allocate space for the whole file
    out.bytes = malloc(fileSize);
    if (out.bytes == NULL) { fclose(fp); return out; }
  }
  out.len = fread(out.bytes, 1 /* element size in bytes */, fileSize /* number of elements to read */, fp);
  fclose(fp);
  if (out.len != fileSize) {
    out.len = 0;
    free(out.bytes);
    out.bytes = NULL;
  }
  return out;
}

str str_clone(const str orig) {
  str out = { .len = orig.len, .bytes = malloc(orig.len) };
  checkOom(out.bytes);
  memcpy(out.bytes, orig.bytes, orig.len);
  return out;
}

size_t peekUchar(uchar* out, str in) {
  if (in.len == 0) {
    *out = UCHAR_NULL;
    return 0;
  }
  else if (!(in.bytes[0] & 0x80) /*0b0xxxxxxx*/) {
    *out = (int32_t)in.bytes[0];
    return 1;
  }
  else if (!(in.bytes[0] & 0x40) /* 0b10xxxxxx */) {
    goto badbyte;
  }
  else if (!(in.bytes[0] & 0x20) /* 0b110xxxxx */) {
    if ( in.len < 2
      || (in.bytes[1] & 0xC0) != 0x80
       ) {
      goto badbyte;
    }
    *out = ((int32_t)in.bytes[0] & 0x1F)<<6
         | ((int32_t)in.bytes[1] & 0x3F)
         ;
    return 2;
  }
  else if (!(in.bytes[0] & 0x10) /* 0b1110xxxx */) {
    if ( in.len < 3
      || ( ((in.bytes[1] & 0xC0) != 0x80)
         | ((in.bytes[2] & 0xC0) != 0x80)
         )
       ) {
      goto badbyte;
    }
    *out = ((int32_t)in.bytes[0] & 0x0F)<<12
         | ((int32_t)in.bytes[1] & 0x3F)<<6
         | ((int32_t)in.bytes[2] & 0x3F)
         ;
    return 3;
  }
  else if (!(in.bytes[0] & 0x08) /* 0b11110xxx */) {
    if ( in.len < 4
      || ( ((in.bytes[1] & 0xC0) != 0x80)
         | ((in.bytes[2] & 0xC0) != 0x80)
         | ((in.bytes[3] & 0xC0) != 0x80)
         )
       ) {
      goto badbyte;
    }
    *out = ((int32_t)in.bytes[0] & 0x07)<<18
         | ((int32_t)in.bytes[1] & 0x3F)<<12
         | ((int32_t)in.bytes[2] & 0x3F)<<6
         | ((int32_t)in.bytes[3] & 0x3F)
         ;
    return 4;
  }
  else badbyte: {
    *out = -(int32_t)in.bytes[0];
    return 1;
  }
}

size_t peekUchars(uchar* out, size_t n, str in) {
  size_t adv = 0;
  for (size_t i = 0; i < n; ++i) {
    size_t adv1 = peekUchar(&out[i], in);
    adv += adv1;
    in.bytes += adv;
    in.len -= adv;
  }
  return adv;
}


bool ucharElem(uchar c, const uchar* set) {
  // if (c == UCHAR_NULL) { return false; } // TODO would this help performance?
  for (size_t i = 0; set[i] != UCHAR_NULL; ++i) {
    if (set[i] == c) { return true; }
  }
  return false;
}
