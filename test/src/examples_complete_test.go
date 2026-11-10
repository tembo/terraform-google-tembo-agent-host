package test

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"slices"
	"strings"
	"testing"

	"github.com/gruntwork-io/terratest/modules/random"
	"github.com/gruntwork-io/terratest/modules/terraform"
	teststructure "github.com/gruntwork-io/terratest/modules/test-structure"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	iam "google.golang.org/api/iam/v1"
)

const (
	region    = "us-central1"
	namespace = "tembo"
)

// project is the Google Cloud project the tests apply examples/complete in.
func project(t *testing.T) string {
	p := os.Getenv("GOOGLE_CLOUD_PROJECT")
	require.NotEmpty(t, p, "set GOOGLE_CLOUD_PROJECT to the project to test in")
	return p
}

func cleanup(t *testing.T, opts *terraform.Options, tempTestFolder string) {
	terraform.Destroy(t, opts)
	os.RemoveAll(tempTestFolder)
}

func options(t *testing.T, vars map[string]any) (*terraform.Options, string) {
	tempTestFolder := teststructure.CopyTerraformFolderToTemp(t, "../../", "examples/complete")

	return &terraform.Options{
		TerraformDir: tempTestFolder,
		Upgrade:      true,
		VarFiles:     []string{"fixtures." + region + ".tfvars"},
		Vars:         vars,
	}, tempTestFolder
}

// TestExamplesComplete applies examples/complete in Google Cloud: a VPC with
// Cloud NAT, a private GKE Autopilot cluster and the module.
func TestExamplesComplete(t *testing.T) {
	t.Parallel()
	projectID := project(t)
	randID := strings.ToLower(random.UniqueId())
	id := "eg-uc1-test-agent-host-" + randID

	opts, tempTestFolder := options(t, map[string]any{
		"attributes": []string{randID},
		"project_id": projectID,
	})
	defer cleanup(t, opts, tempTestFolder)

	terraform.InitAndApply(t, opts)

	clusterName := terraform.Output(t, opts, "cluster_name")
	serviceAccount := terraform.Output(t, opts, "service_account_name")
	controllerEmail := terraform.Output(t, opts, "controller_service_account_email")

	assert.Equal(t, id+"-cluster", clusterName)
	assert.Equal(t, "tembo-host-controller", serviceAccount)
	assert.True(t, strings.HasSuffix(controllerEmail, "@"+projectID+".iam.gserviceaccount.com"), controllerEmail)
	assert.Equal(t, map[string]string{
		"tembo-cluster":   clusterName,
		"tembo-namespace": namespace,
	}, terraform.OutputMap(t, opts, "ownership_labels"))

	// The host controller derives the same prefix when none is set.
	sum := sha256.Sum256([]byte(clusterName + "/" + namespace))
	assert.Equal(t, "tembo-"+hex.EncodeToString(sum[:])[:8]+"-", terraform.Output(t, opts, "instance_name_prefix"))

	// The controller's Kubernetes service account may act as its Google one.
	iamService, err := iam.NewService(context.Background())
	require.NoError(t, err)
	policy, err := iamService.Projects.ServiceAccounts.GetIamPolicy("projects/" + projectID + "/serviceAccounts/" + controllerEmail).Do()
	require.NoError(t, err)
	member := "serviceAccount:" + projectID + ".svc.id.goog[" + namespace + "/" + serviceAccount + "]"
	assert.True(t, slices.ContainsFunc(policy.Bindings, func(b *iam.Binding) bool {
		return b.Role == "roles/iam.workloadIdentityUser" && slices.Contains(b.Members, member)
	}), "no Workload Identity binding for %s", member)

	// A second plan finds nothing to change.
	assert.Equal(t, 0, terraform.PlanExitCode(t, opts))
}

// TestExamplesCompleteDisabled applies examples/complete with enabled = false,
// which creates nothing.
func TestExamplesCompleteDisabled(t *testing.T) {
	t.Parallel()
	randID := strings.ToLower(random.UniqueId())

	opts, tempTestFolder := options(t, map[string]any{
		"attributes": []string{randID},
		"project_id": project(t),
		"enabled":    false,
	})
	defer cleanup(t, opts, tempTestFolder)

	results := terraform.InitAndApply(t, opts)

	assert.Contains(t, results, "Resources: 0 added, 0 changed, 0 destroyed.")
}
