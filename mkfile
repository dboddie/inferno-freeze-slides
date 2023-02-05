default:V:
	groff -ms -Tps freeze.ms > /tmp/freeze.ps
	ps2pdf /tmp/freeze.ps /tmp/freeze.pdf
