"""Measure field-rate detail after fitting, rather than just the filter-enable bit.

The source sinusoid becomes alternating output lines: exactly the detail that
flashes between fields on a CRT. Average over source phases so a lucky sampling
phase cannot hide a weak filter. Pixel RTL equivalence is tested separately by
disp_reader_tb; this test supplies the missing picture-quality requirement.
"""
import math
import unittest

from disp_fit_ref import fit


def field_detail(f, height):
    step, box, weight = f['sy'] / 65536, f['dv'], f['vpf'] / 8
    energy = []
    for phase in range(16):
        source = [math.cos(math.pi * y / step + phase * math.pi / 8)
                  for y in range(height)]
        rows = [sum(source[y:y + box]) / box
                for y in range(0, height, box)]
        rows = [(1 - weight) * a + weight * b
                for a, b in zip(rows, rows[1:])]
        output = []
        for line in range(20, f['oh'] - 20):
            position = (line * step + step / 2 - .5 - (box - 1) / 2
                        - box * weight) / box
            index = math.floor(position)
            fraction = position - index
            output.append(rows[index] * (1 - fraction) + rows[index + 1] * fraction)
        mean = sum(output) / len(output)
        energy.append(sum((v - mean) ** 2 for v in output) / len(output))
    return math.sqrt(sum(energy) / len(energy))


class DeflickerStrength(unittest.TestCase):
    def test_scaled_field_detail_is_at_least_halved(self):
        # Include 720-line video and a nearby cropped-size class, both sides
        # of the former weak interval, native 480, and a 2:1 reduction.
        for output, heights in ((480, (480, 592, 720, 736, 832, 960)),
                                (576, (576, 720, 864, 880, 1024))):
            for width in (40, 60, 80):
                for height in heights:
                    if width * (height // 16) > 3600:
                        continue
                    with self.subTest(output=output, width=width, height=height):
                        args = dict(w_mbs=width, hf_mbs=height // 16, mode='fill',
                                    il=True, dw=0, dh=0, pal=output == 576, flt='area')
                        off, on = fit(**args), fit(**args, at=True)
                        self.assertEqual((off['ow'], off['oh']), (on['ow'], on['oh']))
                        self.assertLess(field_detail(on, height),
                                        field_detail(off, height) * .5)


if __name__ == '__main__':
    unittest.main()
