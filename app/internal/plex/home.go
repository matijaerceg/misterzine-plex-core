package plex

import (
	"bytes"
	"encoding/json"
	"encoding/xml"
	"fmt"
	"io"
	"net/url"
	"strings"
)

// AccountHomeIdentity reads the signed-in account's own identity and whether
// Plex considers it a member of a Plex Home. The bool is the Home membership
// flag; a non-Home account can use its account token directly without calling
// the Home-only list and switch endpoints.
func AccountHomeIdentity(clientID, token string) (HomeUser, bool, error) {
	r, err := tvReq("GET", "/api/v2/user", token, clientID, nil)
	if err != nil {
		return HomeUser{}, false, err
	}
	body, err := tvDo(r)
	if err != nil {
		return HomeUser{}, false, err
	}
	var account struct {
		ID         json.RawMessage `json:"id"`
		Title      string          `json:"title"`
		Friendly   string          `json:"friendlyName"`
		Username   string          `json:"username"`
		Home       *bool           `json:"home"`
		Protected  *bool           `json:"protected"`
		Restricted *bool           `json:"restricted"`
	}
	if err := json.Unmarshal(body, &account); err != nil {
		return HomeUser{}, false, fmt.Errorf("invalid Plex account identity response")
	}
	if account.Home == nil || len(account.ID) == 0 || string(account.ID) == "null" {
		return HomeUser{}, false, fmt.Errorf("Plex account identity response is incomplete")
	}
	var id string
	if err := json.Unmarshal(account.ID, &id); err != nil {
		var numeric json.Number
		if err := json.Unmarshal(account.ID, &numeric); err != nil {
			return HomeUser{}, false, fmt.Errorf("Plex account identity response is incomplete")
		}
		id = numeric.String()
	}
	if strings.TrimSpace(id) == "" {
		return HomeUser{}, false, fmt.Errorf("Plex account identity response is incomplete")
	}
	title := strings.TrimSpace(account.Title)
	if title == "" {
		title = strings.TrimSpace(account.Friendly)
	}
	if title == "" {
		title = strings.TrimSpace(account.Username)
	}
	if title == "" {
		return HomeUser{}, false, fmt.Errorf("Plex account identity response is incomplete")
	}
	user := HomeUser{ID: id, Title: title}
	// A non-Home Plex account has no Home PIN or managed-user restrictions;
	// older account responses can omit these Home-only fields. For Home
	// members, missing flags fail closed until the member list is available.
	if *account.Home {
		user.Protected = account.Protected == nil || *account.Protected
		user.Restricted = account.Restricted == nil || *account.Restricted
	} else {
		user.Protected = account.Protected != nil && *account.Protected
		user.Restricted = account.Restricted != nil && *account.Restricted
	}
	return user, *account.Home, nil
}

// HomeUser is a member of the signed-in account's Plex Home.
type HomeUser struct {
	ID         string
	Title      string
	Protected  bool
	Restricted bool
}

// HomeUsers lists the accounts in the Plex Home for token.
func HomeUsers(clientID, token string) ([]HomeUser, error) {
	r, err := tvReq("GET", "/api/home/users", token, clientID, nil)
	if err != nil {
		return nil, err
	}
	r.Header.Set("Accept", "application/xml")
	body, err := tvDo(r)
	if err != nil {
		return nil, err
	}
	var response struct {
		XMLName xml.Name `xml:"MediaContainer"`
		Users   []struct {
			ID         string `xml:"id,attr"`
			Title      string `xml:"title,attr"`
			Protected  string `xml:"protected,attr"`
			Restricted string `xml:"restricted,attr"`
		} `xml:"User"`
	}
	if err := xml.Unmarshal(body, &response); err != nil {
		return nil, fmt.Errorf("invalid Plex Home users response")
	}
	if response.XMLName.Local != "MediaContainer" {
		return nil, fmt.Errorf("invalid Plex Home users response")
	}
	users := make([]HomeUser, 0, len(response.Users))
	for _, u := range response.Users {
		if strings.TrimSpace(u.ID) == "" {
			return nil, fmt.Errorf("Plex Home user response is missing an ID")
		}
		protected, protectedKnown := parsePlexBool(u.Protected)
		if !protectedKnown {
			protected = true
		}
		restricted, restrictedKnown := parsePlexBool(u.Restricted)
		if !restrictedKnown {
			restricted = true
		}
		users = append(users, HomeUser{ID: u.ID, Title: u.Title,
			Protected: protected, Restricted: restricted})
	}
	return users, nil
}

// SwitchHomeUser switches the account token to a Plex Home member and returns
// the member-scoped token. The PIN is sent in the form body, never the URL.
func SwitchHomeUser(clientID, token, userID, pin string) (string, error) {
	if strings.TrimSpace(userID) == "" {
		return "", fmt.Errorf("Plex Home user ID is required")
	}
	path := "/api/home/users/" + url.PathEscape(userID) + "/switch"
	r, err := tvReq("POST", path, token, clientID, nil)
	if err != nil {
		return "", err
	}
	r.Header.Set("Accept", "application/xml")
	form := url.Values{}
	if pin != "" {
		form.Set("pin", pin)
	}
	r.Body = io.NopCloser(bytes.NewBufferString(form.Encode()))
	r.ContentLength = int64(len(form.Encode()))
	r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	body, err := tvDo(r)
	if err != nil {
		return "", err
	}
	var response struct {
		XMLName             xml.Name `xml:"user"`
		AuthenticationToken string   `xml:"authenticationToken,attr"`
	}
	if err := xml.Unmarshal(body, &response); err != nil {
		return "", fmt.Errorf("invalid Plex Home switch response")
	}
	if response.XMLName.Local != "user" {
		return "", fmt.Errorf("invalid Plex Home switch response")
	}
	if response.AuthenticationToken == "" {
		return "", fmt.Errorf("Plex Home switch response did not include an authentication token")
	}
	return response.AuthenticationToken, nil
}

func parsePlexBool(value string) (bool, bool) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "1", "true":
		return true, true
	case "0", "false":
		return false, true
	default:
		return false, false
	}
}
