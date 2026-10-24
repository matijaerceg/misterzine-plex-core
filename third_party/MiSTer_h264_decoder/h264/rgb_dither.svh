// 16x16 Bayer rank: every threshold 0..255 once. Used at Q8 -> integer
// rounding, not added to already rounded RGB or encoded component signals.
function automatic [7:0] rgb_dither_rank(input [3:0] dx, input [3:0] dy);
    begin
        rgb_dither_rank = {dx[0]^dy[0], dy[0], dx[1]^dy[1], dy[1],
                           dx[2]^dy[2], dy[2], dx[3]^dy[3], dy[3]};
    end
endfunction
