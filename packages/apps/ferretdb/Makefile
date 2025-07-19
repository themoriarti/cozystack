include ../../../scripts/package.mk
PRESET_ENUM := ["nano","micro","small","medium","large","xlarge","2xlarge"]

generate:
	readme-generator-for-helm -v values.yaml -s values.schema.json -r README.md
	yq -i -o json --indent 4 '.properties.resourcesPreset.enum = $(PRESET_ENUM)' values.schema.json

update:
	tag=$$(git ls-remote --tags --sort="v:refname" https://github.com/FerretDB/FerretDB | awk -F'[/^]' '{sub("^v", "", $$3)} END{print $$3}') && \
	pgtag=$$(skopeo list-tags docker://ghcr.io/ferretdb/postgres-documentdb | jq -r --arg tag "$$tag" '.Tags[] | select(endswith("ferretdb-" + $$tag))' | sort -V | tail -n1) && \
	sed -i "s|\(imageName: ghcr.io/ferretdb/postgres-documentdb:\).*|\1$$pgtag|" templates/postgres.yaml && \
	sed -i "s|\(image: ghcr.io/ferretdb/ferretdb:\).*|\1$$tag|" templates/ferretdb.yaml && \
	sed -i "s|\(appVersion: \).*|\1$$tag|" Chart.yaml
