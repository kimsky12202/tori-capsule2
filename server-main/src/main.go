package main

import (
	"log"
	"net/http"
	"os"

	"github.com/pocketbase/pocketbase"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/hook"
)

func main() {
	app := pocketbase.New()

	// Test route to verify route registration works
	app.OnServe().Bind(&hook.Handler[*core.ServeEvent]{
		Func: func(e *core.ServeEvent) error {
			e.Router.POST("/test", func(re *core.RequestEvent) error {
				return re.JSON(http.StatusOK, map[string]string{"message": "test route works"})
			})
			return e.Next()
		},
	})

	registerLoginRoute(app)
	registerRegisterRoute(app)
	registerVerificationRoute(app)

	// If no args, run serve by default
	if len(os.Args) == 1 {
		os.Args = append(os.Args, "serve")
	}

	if err := app.Start(); err != nil {
		log.Fatal(err)
	}
}
