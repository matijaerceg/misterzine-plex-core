# JM 18.4 trace -> macroblock class census, for a stream of ONE IDR (1350 MBs, 720x480)
# followed by P pictures only (checked with hdr_summary.py first). Two JM trace quirks:
#  * JM prints the NEXT slice's header before the current picture's macroblocks, so the
#    slice type cannot be taken from "SH: slice_type"; the first 1350 mb_type lines are the IDR.
#  * CABAC mb_skip_flag is traced inverted: (1) = coded, (0) = skipped (cabac.c).
#  * mb_type: I slices print the syntax value (0 I_NxN, 1..24 I_16x16, 25 I_PCM); P slices
#    print JM's own code (readMB_typeInfo_CABAC_p_slice): 1..5 inter, 6 I_NxN, 7..30 I_16x16, 31 I_PCM.
function val(s,  m) { if (match(s, /\( *-?[0-9]+\) *$/)) { m = substr(s, RSTART + 1, RLENGTH - 2); gsub(/[ )]/, "", m); return m + 0 } return -1 }
/^@[0-9]+ +mb_skip_flag/    { if (val($0) == 0) n["skip"]++; next }
/^@[0-9]+ +mb_type/         { v = val($0); nm++
                              if (nm <= 1350) cur = (v == 0) ? "intraNxN" : (v <= 24) ? "I16x16" : "PCM"
                              else            cur = (v <= 5) ? "inter" : (v == 6) ? "intraNxN" : (v <= 30) ? "I16x16" : "PCM"
                              n[cur]++; next }
/^@[0-9]+ +transform_size_8x8_flag/ { if (val($0) == 1) n[cur "_t8"]++; next }
END {
  tot = n["skip"] + n["inter"] + n["intraNxN"] + n["I16x16"] + n["PCM"]; coded = tot - n["skip"]
  i8 = n["intraNxN_t8"]; i4 = n["intraNxN"] - i8; t8 = n["inter_t8"]
  printf "MBs %d (%.1f pictures)  skip %.1f%%  inter %.1f%%  I4x4 %.2f%%  I8x8 %.2f%%  I16x16 %.2f%%  PCM %d\n",
    tot, tot / 1350, 100*n["skip"]/tot, 100*n["inter"]/tot, 100*i4/tot, 100*i8/tot, 100*n["I16x16"]/tot, n["PCM"]
  printf "  of coded MBs: inter with the 8x8 transform %.1f%%, I8x8 %.2f%%  -> any 8x8 tool %.1f%%\n",
    100*t8/coded, 100*i8/coded, 100*(t8 + i8)/coded
}
