include ../../../scripts/package.mk

generate:
	readme-generator -v values.yaml -s values.schema.json -r README.md
	yq -i -o json --indent 2 '.properties.httpAndHttps.properties.mode.enum = ["tcp","tcp-with-proxy"]' values.schema.json
	yq -i -o json --indent 2 '.properties.resourcesPreset.enum = ["none", "nano", "micro", "small", "medium", "large", "xlarge", "2xlarge"]' values.schema.json
	rm -f values.schema.json.tmp
