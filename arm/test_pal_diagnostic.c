#include "pal_diagnostic.h"
#include <assert.h>
static unsigned calls;
static void emit(unsigned type,const uint8_t *p,size_t n) {
 assert(type==7 || type==8); assert(n>0 && n<=512);assert((p[0]&31)==type);++calls;
}
int main(void) {
 struct pal_headers s={0};
 const uint8_t a[]={0,0,0,1,0x67,42,0,0,1,0x68,17,0,0,1,0x65,99,0,0,1,6,88};
 pal_capture_headers(&s,a,sizeof a,emit);assert(calls==2);
 pal_capture_headers(&s,a,sizeof a,emit);assert(calls==2);
 for(size_t n=0;n<sizeof a;n++) {struct pal_headers t={0};pal_capture_headers(&t,a,n,emit);}
 calls=0;uint8_t b[600]={0,0,1,0x67};pal_capture_headers(&s,b,sizeof b,emit);assert(calls==0);
 for(unsigned i=0;i<30;i++){uint8_t c[]={0,0,1,0x67,(uint8_t)i};pal_capture_headers(&s,c,sizeof c,emit);}
 assert(s.emitted==16 && calls==14);return 0;
}
