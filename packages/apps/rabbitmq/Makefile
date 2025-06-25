include ../../../scripts/package.mk

generate:
	readme-generator -v values.yaml -s values.schema.json -r README.md
	yq -i -o json --indent 4 '.properties.resourcesPreset.enum = ["none", "nano", "micro", "small", "medium", "large", "xlarge", "2xlarge"]' values.schema.json
