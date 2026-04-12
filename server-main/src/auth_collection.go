package main

import (
	"fmt"

	"github.com/pocketbase/pocketbase"
	"github.com/pocketbase/pocketbase/core"
)

func findAuthCollection(app *pocketbase.PocketBase) (*core.Collection, error) {
	if col, err := app.FindCollectionByNameOrId("users"); err == nil {
		return col, nil
	}

	if col, err := app.FindCollectionByNameOrId("_pb_users_auth_"); err == nil {
		return col, nil
	}

	return nil, fmt.Errorf("auth collection not found (tried users and _pb_users_auth_)")
}