.DEFAULT_GOAL := test

## Run the Terratest suite, which applies examples/complete in GOOGLE_CLOUD_PROJECT
test:
	go mod download
	go test -v -timeout 90m

## Remove state the tests leave behind
clean:
	rm -rf ../../examples/complete/*.tfstate* ../../examples/complete/.terraform ../../examples/complete/.terraform.lock.hcl

.PHONY: test clean
