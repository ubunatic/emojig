// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

package emoji

import "testing"

func TestDetectDisableZWJ(t *testing.T) {
	cases := []struct {
		name string
		env  map[string]string
		want bool
	}{
		{"clean", map[string]string{}, false},
		{"tilix", map[string]string{"TILIX_ID": "x"}, true},
		{"vte", map[string]string{"VTE_VERSION": "6800"}, true},
		{"explicit on", map[string]string{"EMOJIG_DISABLE_ZWJ": "1"}, true},
		{"explicit true", map[string]string{"EMOJIG_DISABLE_ZWJ": "true"}, true},
		{"explicit off beats tilix", map[string]string{"EMOJIG_DISABLE_ZWJ": "0", "TILIX_ID": "x"}, false},
		{"explicit false beats vte", map[string]string{"EMOJIG_DISABLE_ZWJ": "false", "VTE_VERSION": "6800"}, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			for _, k := range []string{"EMOJIG_DISABLE_ZWJ", "TILIX_ID", "VTE_VERSION"} {
				t.Setenv(k, "")
			}
			for k, v := range c.env {
				t.Setenv(k, v)
			}
			if got := detectDisableZWJ(); got != c.want {
				t.Errorf("detectDisableZWJ() = %v, want %v", got, c.want)
			}
		})
	}
}
