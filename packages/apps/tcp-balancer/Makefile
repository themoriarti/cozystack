include ../../../scripts/package.mk
PRESET_ENUM := ["nano","micro","small","medium","large","xlarge","2xlarge"]

generate:
	readme-generator-for-helm -v values.yaml -s values.schema.json -r README.md
	yq -i -o json --indent 2 '.properties.httpAndHttps.properties.mode.enum = ["tcp","tcp-with-proxy"]' values.schema.json
	yq -i -o json --indent 2 '.properties.resourcesPreset.enum = $(PRESET_ENUM)' values.schema.json
	rm -f values.schema.json.tmp
