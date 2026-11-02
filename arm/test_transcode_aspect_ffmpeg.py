#!/usr/bin/env python3
"""Optional integration check: cc, ffmpeg with libx264, and ffprobe required.

Generate synthetic H.264, run the production stale-SAR predicate, and check
the selected bitstream filter's output metadata and decoded picture hashes.
"""
import ctypes
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent


def run(args):
    return subprocess.run(list(map(str, args)), check=True, capture_output=True, text=True).stdout


def ff(*args):
    return run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", *args])


def probe(path):
    return json.loads(run(["ffprobe", "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=width,height,sample_aspect_ratio,display_aspect_ratio", "-of", "json", path]))["streams"][0]


def main():
    with tempfile.TemporaryDirectory(prefix="transcode-aspect-") as tmp:
        tmp = Path(tmp)
        (tmp / "policy.c").write_text('''#include "transcode_aspect.h"
int repair(int iw,int ih,double dar,int w,int h,int sn,int sd) {
    struct transcode_source s={iw,ih,dar};
    return transcode_aspect_stale(s,w,h,sn,sd);
}
''')
        run([os.environ.get("CC", "cc"), "-shared", "-fPIC", "-I", HERE, tmp/"policy.c", "-o", tmp/"policy.so"])
        policy = ctypes.CDLL(str(tmp/"policy.so")).repair
        policy.argtypes = [ctypes.c_int,ctypes.c_int,ctypes.c_double,ctypes.c_int,ctypes.c_int,ctypes.c_int,ctypes.c_int]
        policy.restype = ctypes.c_int
        cases = [
            ("stale-4x3", 720,480,1.33, 640,480,8,9, True,"1:1","4:3"),
            ("correct-4x3", 720,480,1.33, 640,480,1,1, False,"1:1","4:3"),
            ("original-anamorphic", 720,480,1.33, 720,480,8,9, False,"8:9","4:3"),
            ("intentional-narrow", 640,480,32/27, 640,480,8,9, False,"8:9","32:27"),
            ("stale-wide", 720,480,1.78, 854,480,32,27, True,"1:1","427:240"),
        ]
        for name,iw,ih,dar,w,h,sn,sd,want_repair,want_sar,want_dar in cases:
            source = tmp/(name+".mkv")
            output = tmp/(name+".h264")
            ff("-f","lavfi","-i",f"testsrc2=size={w}x{h}:rate=24","-frames:v","3",
               "-vf",f"setsar={sn}/{sd}","-c:v","libx264","-preset","fast","-an",source)
            info = probe(source)
            observed = tuple(map(int, info["sample_aspect_ratio"].split(":")))
            repair = bool(policy(iw,ih,dar,info["width"],info["height"],*observed))
            assert repair == want_repair, (name,repair)
            chain = "h264_mp4toannexb" + (",h264_metadata=sample_aspect_ratio=1/1" if repair else "")
            ff("-i",source,"-map","0:v:0","-c","copy","-bsf:v",chain,"-f","h264",output)
            info = probe(output)
            assert info["sample_aspect_ratio"] == want_sar and info["display_aspect_ratio"] == want_dar, (name,info)
            hashes=[]
            for path in (source,output):
                md5=ff("-i",path,"-map","0:v:0","-f","framemd5","-")
                hashes.append([line.rsplit(",",1)[-1].strip() for line in md5.splitlines() if line and not line.startswith("#")])
            assert hashes[0] == hashes[1], name+": pixels changed"
            print(name+": metadata and unchanged decoded pixels passed")
            if name == "stale-4x3":
                # The worker can also adjust film speed in this filter chain.
                ff("-i",source,"-map","0:v:0","-c","copy","-bsf:v",
                   chain+",h264_metadata=tick_rate=50/1","-f","h264",output)
                info = probe(output)
                assert info["sample_aspect_ratio"] == "1:1" and info["display_aspect_ratio"] == "4:3", info
                trace = subprocess.run(["ffmpeg", "-hide_banner", "-i", str(output),
                    "-c", "copy", "-bsf:v", "trace_headers", "-f", "null", "-"],
                    check=True, capture_output=True, text=True).stderr
                assert re.search(r"num_units_in_tick\s+\S+\s+= 1\b", trace), trace
                assert re.search(r"time_scale\s+\S+\s+= 50\b", trace), trace
                md5 = ff("-i",output,"-map","0:v:0","-f","framemd5","-")
                frames = [line.rsplit(",",1)[-1].strip() for line in md5.splitlines() if line and not line.startswith("#")]
                assert frames == hashes[0], "film speed: pixels changed"
                print("stale-4x3 with film speed: shape, cadence and unchanged decoded pixels passed")


if __name__ == "__main__":
    main()
