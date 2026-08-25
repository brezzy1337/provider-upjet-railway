// Package railway holds the hand-written Upjet configuration for the Railway
// resources: cross-resource references so a managed resource can point at the
// Project/Service/Environment it belongs to by Kubernetes name instead of a
// raw Railway ID.
package railway

import "github.com/crossplane/upjet/v2/pkg/config"

// references maps the Terraform attribute name to the Terraform resource it
// identifies. Upjet generates `<field>Ref` / `<field>Selector` for each.
var references = map[string]config.Reference{
	"project_id":     {TerraformName: "railway_project"},
	"service_id":     {TerraformName: "railway_service"},
	"environment_id": {TerraformName: "railway_environment"},
}

// resourcesWithReferences lists every resource that carries one or more of the
// attributes above; the generator only adds refs for attributes that exist in
// the resource schema, so listing a superset is harmless.
var resourcesWithReferences = []string{
	"railway_environment",
	"railway_service",
	"railway_variable",
	"railway_variable_collection",
	"railway_shared_variable",
	"railway_custom_domain",
	"railway_service_domain",
	"railway_tcp_proxy",
}

// Configure applies the Railway-specific resource configuration.
func Configure(p *config.Provider) {
	for _, name := range resourcesWithReferences {
		p.AddResourceConfigurator(name, func(r *config.Resource) {
			for attr, ref := range references {
				if _, ok := r.TerraformResource.Schema[attr]; ok {
					r.References[attr] = ref
				}
			}
		})
	}
}
