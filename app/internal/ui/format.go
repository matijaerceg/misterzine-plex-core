package ui

import "strconv"

func itoa(n int) string { return strconv.Itoa(n) }

// clock formats seconds as h:mm:ss or m:ss.
func clock(sec int) string {
	h, m, s := sec/3600, sec%3600/60, sec%60
	if h > 0 {
		return itoa(h) + ":" + pad2(m) + ":" + pad2(s)
	}
	return itoa(m) + ":" + pad2(s)
}

func pad2(n int) string {
	if n < 10 {
		return "0" + itoa(n)
	}
	return itoa(n)
}
