package main

import (
	"database/sql"
	"errors"
	"net/http"
	"strings"

	"github.com/pocketbase/pocketbase"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/hook"
)

type loginRequest struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

func registerLoginRoute(app *pocketbase.PocketBase) {
	app.OnServe().Bind(&hook.Handler[*core.ServeEvent]{
		Func: func(e *core.ServeEvent) error {
			e.Router.POST("/users/login", func(re *core.RequestEvent) error {
				var body loginRequest
				if err := re.BindBody(&body); err != nil {
					return re.JSON(http.StatusBadRequest, map[string]string{"message": err.Error()})
				}

				email := strings.TrimSpace(body.Email)
				password := body.Password

				if email == "" || password == "" {
					return re.JSON(http.StatusBadRequest, map[string]string{"message": "email and password are required"})
				}

				user, err := app.FindFirstRecordByData("users", "email", email)
				if err != nil {
					if errors.Is(err, sql.ErrNoRows) {
						return re.JSON(http.StatusUnauthorized, map[string]string{"message": "email or password is incorrect"})
					}

					return re.JSON(http.StatusInternalServerError, map[string]string{"message": "failed to find user"})
				}

				if !user.ValidatePassword(password) {
					return re.JSON(http.StatusUnauthorized, map[string]string{"message": "email or password is incorrect"})
				}

				if !user.Verified() {
					return re.JSON(http.StatusForbidden, map[string]string{"message": "email verification is required"})
				}

				token, err := user.NewAuthToken()
				if err != nil {
					return re.JSON(http.StatusInternalServerError, map[string]string{"message": err.Error()})
				}

				return re.JSON(http.StatusOK, map[string]any{
					"token": map[string]string{
						"access_token": token,
						"token_type":   "Bearer",
					},
					"user": map[string]any{
						"id":       user.Id,
						"email":    user.Email(),
						"username": firstNonEmpty(user.GetString("username"), user.GetString("name")),
					},
				})
			})
			return e.Next()
		},
	})
}
