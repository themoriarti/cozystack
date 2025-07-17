include ../../../scripts/package.mk
PRESET_ENUM := ["nano","micro","small","medium","large","xlarge","2xlarge"]

generate:
	readme-generator-for-helm -v values.yaml -s values.schema.json -r README.md
	yq -i -o json --indent 4 '.properties.kafka.properties.resourcesPreset.enum = $(PRESET_ENUM)' values.schema.json
	yq -i -o json --indent 4 '.properties.zookeeper.properties.resourcesPreset.enum = $(PRESET_ENUM)' values.schema.json
