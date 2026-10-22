#include <assert.h>
#include <stdio.h>
#include "h264_idr.h"

int main(void)
{
    /* Length 261 looks like 00 00 01 05: it is not a start code/IDR. */
    uint8_t non_idr[265] = {0, 0, 1, 5, 0x41};
    assert(!h264_packet_idr(non_idr, sizeof non_idr, 4));
    const uint8_t avcc[] = {0,0,0,2,0x65,0x88, 0,0,0,2,0x41,0x88};
    assert(h264_packet_idr(avcc, sizeof avcc, 4));
    assert(!h264_packet_idr(avcc, sizeof avcc-1, 4));
    const uint8_t annexb[] = {0,0,0,1,0x67,0x88,0,0,1,0x65,0x88};
    assert(h264_packet_idr(annexb, sizeof annexb, 0));
    const uint8_t invalid[] = {0,0,1,0x85,0x88};
    const uint8_t nonref[] = {0,0,1,0x05,0x88};
    const uint8_t truncated[] = {0,0,1,0x65,0x88,0,0,1};
    assert(!h264_packet_idr(invalid, sizeof invalid, 0));
    assert(!h264_packet_idr(nonref, sizeof nonref, 0));
    assert(!h264_packet_idr(truncated, sizeof truncated, 0));
    assert(!h264_packet_idr(NULL, 0, 0));
    puts("H.264 IDR framing tests passed");
    return 0;
}
