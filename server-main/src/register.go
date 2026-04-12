package main

import (
	"database/sql"
	"errors"
	"net/http"
	"regexp"
	"strings"

	"github.com/pocketbase/pocketbase"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/mails"
	"github.com/pocketbase/pocketbase/tools/hook"
)

var emailPattern = regexp.MustCompile(`^[^@\s]+@[^@\s]+\.[^@\s]+$`)

type registerRequest struct {
	Email           string `json:"email"`
	Username        string `json:"username"`
	Password        string `json:"password"`
	PasswordConfirm string `json:"passwordConfirm"`
}

func registerRegisterRoute(app *pocketbase.PocketBase) {
	app.OnServe().Bind(&hook.Handler[*core.ServeEvent]{
		Func: func(e *core.ServeEvent) error {
			e.Router.POST("/users", func(re *core.RequestEvent) error {
				var body registerRequest
				if err := re.BindBody(&body); err != nil {
					return re.JSON(http.StatusBadRequest, map[string]string{"message": err.Error()})
				}

				email := strings.TrimSpace(body.Email)
				username := strings.TrimSpace(body.Username)
				password := body.Password
				passwordConfirm := body.PasswordConfirm

				if email == "" || username == "" || password == "" || passwordConfirm == "" {
					return re.JSON(http.StatusBadRequest, map[string]string{"message": "email, username, password and passwordConfirm are required"})
				}

				if password != passwordConfirm {
					return re.JSON(http.StatusBadRequest, map[string]string{"message": "passwords don't match"})
				}

				if !emailPattern.MatchString(email) {
					return re.JSON(http.StatusBadRequest, map[string]string{"message": "invalid email format"})
				}

				if _, err := app.FindFirstRecordByData("users", "email", email); err == nil {
					return re.JSON(http.StatusConflict, map[string]string{"message": "email already registered"})
				} else if !errors.Is(err, sql.ErrNoRows) {
					return re.JSON(http.StatusBadRequest, map[string]string{"message": err.Error()})
				}

				usersCol, err := app.FindCollectionByNameOrId("users")
				if err != nil {
					return re.JSON(http.StatusInternalServerError, map[string]string{"message": err.Error()})
				}

				hasUsernameField := usersCol.Fields.GetByName("username") != nil
				hasNameField := usersCol.Fields.GetByName("name") != nil
				if hasUsernameField {
					if _, err := app.FindFirstRecordByData("users", "username", username); err == nil {
						return re.JSON(http.StatusConflict, map[string]string{"message": "username already taken"})
					} else if !errors.Is(err, sql.ErrNoRows) {
						return re.JSON(http.StatusBadRequest, map[string]string{"message": err.Error()})
					}
				}

				user := core.NewRecord(usersCol)
				user.Set("email", email)
				user.SetVerified(false)
				user.Set("password", password)
				user.Set("passwordConfirm", passwordConfirm)

				if hasUsernameField {
					user.Set("username", username)
				}
				if hasNameField {
					user.Set("name", username)
				}

				if err := app.Save(user); err != nil {
					return re.JSON(http.StatusBadRequest, map[string]string{"message": err.Error()})
				}

				if err := mails.SendRecordVerification(app, user); err != nil {
					return re.JSON(http.StatusInternalServerError, map[string]string{"message": "failed to send verification email"})
				}

				user.Hide("password", "passwordConfirm", "tokenKey")

				return re.JSON(http.StatusCreated, map[string]any{
					"message": "registration completed. please verify your email.",
					"user": map[string]string{
						"id":       user.Id,
						"email":    user.GetString("email"),
						"username": firstNonEmpty(user.GetString("username"), user.GetString("name")),
						"created":  user.GetString("created"),
					},
				})
			})

			return e.Next()
		},
	})
}
