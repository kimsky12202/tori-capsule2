package main

import (
	"database/sql"
	"errors"
	"net/http"
	"strings"

	"github.com/pocketbase/pocketbase"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/mails"
	"github.com/pocketbase/pocketbase/tools/hook"
)

type verificationRequest struct {
	Email string `json:"email"`
}

func registerVerificationRoute(app *pocketbase.PocketBase) {
	app.OnServe().Bind(&hook.Handler[*core.ServeEvent]{
		Func: func(e *core.ServeEvent) error {
			e.Router.POST("/users/request-verification", func(re *core.RequestEvent) error {
				var body verificationRequest
				if err := re.BindBody(&body); err != nil {
					return re.JSON(http.StatusBadRequest, map[string]string{"message": err.Error()})
				}

				email := strings.TrimSpace(body.Email)
				if email == "" {
					return re.JSON(http.StatusBadRequest, map[string]string{"message": "email is required"})
				}

				user, err := app.FindFirstRecordByData("users", "email", email)
				if err != nil {
					if errors.Is(err, sql.ErrNoRows) {
						return re.JSON(http.StatusNotFound, map[string]string{"message": "user not found"})
					}

					return re.JSON(http.StatusInternalServerError, map[string]string{"message": "failed to find user"})
				}

				if user.Verified() {
					return re.JSON(http.StatusBadRequest, map[string]string{"message": "email is already verified"})
				}

				if err := mails.SendRecordVerification(app, user); err != nil {
					return re.JSON(http.StatusInternalServerError, map[string]string{"message": "failed to send verification email"})
				}

				return re.JSON(http.StatusOK, map[string]string{"message": "verification email sent"})
			})

			return e.Next()
		},
	})
}
