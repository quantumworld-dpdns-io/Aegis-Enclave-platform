# 閘道授權政策：以角色決定能否存取 vault／碳權退役。
# 輸入由 middleware 提供，subject 已是假名，政策不接觸原始身分。
package aegis.authz

import rego.v1

default decision := {"allow": false, "reason": "policy:deny"}

vault_read_roles := {"analyst", "vault_reader", "admin"}
vault_write_roles := {"analyst", "vault_writer", "admin"}
carbon_roles := {"operator", "carbon_operator", "admin"}

decision := {"allow": true, "reason": "policy:vault_reader"} if {
	input.method == "GET"
	startswith(input.path, "/api/v1/vault/records")
	input.role in vault_read_roles
}

decision := {"allow": true, "reason": "policy:vault_writer"} if {
	input.method == "POST"
	input.path == "/api/v1/vault/records"
	input.role in vault_write_roles
}

decision := {"allow": true, "reason": "policy:carbon_operator"} if {
	input.method == "POST"
	input.path == "/api/v1/carbon/retire"
	input.role in carbon_roles
}
