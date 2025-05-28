OUT=../_out/repos/library
TMP := $(shell mktemp -d)

repo:
	cd .. && ../hack/package_chart.sh library $(OUT) $(TMP)

fix-chartnames:
	find . -maxdepth 2 -name Chart.yaml  | awk -F/ '{print $$2}' | while read i; do sed -i "s/^name: .*/name: $$i/" "$$i/Chart.yaml"; done
