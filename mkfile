default:V:
	groff -ms -Tps -F/tmp/font freeze.ms > /tmp/freeze.ps
	ps2pdf /tmp/freeze.ps /tmp/freeze.pdf
