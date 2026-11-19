# RLA work: what exists and how to restore it (2026-10-26)

## Data (BANKCRFM, CAS)
| Object | What it is |
|---|---|
| `RETAIL_LOAN_APPLICATIONS` | Main table, 50,000 rows, 110 columns (date_of_birth_dt, gender randomised; `age`, `reject_flg` added) |
| `RETAIL_LOAN_APPLICATIONS_BKP`, `_BKP2`, `_BKP3` | Backups taken before each change |
| `RLA_BACKUP_20261026` | Dated backup from `backup_rla.sas` |
| `ALL_APPLICATION_DIM` | Shared table we appended RLA applications to |
| `ALL_APPLICATION_DIM_BKP`, `_BKP2` | Backups from before the append and the date-format change |
| `ALL_APP_DIM_AFTER_RLA_1026` | Copy of the appended table, 26 Oct (from `backup_rla.sas`) |
| `CRD_APPLICATIONS_ORIGINAL` | Rollback copy of the CRD table |
| `retail_loan_applications_backup_20261026.csv` | CSV in SAS Content > My Folder |

Restore a table: load the `.sashdat` with `proc casutil ... load casdata="NAME.sashdat" casout="NAME"` into CASUSER, then `droptable` the live table, `save ... replace` and `promote`.

## Risk Modeling objects (re-create from the files here if lost)
| Object | Detail |
|---|---|
| Data source | Retail Loan Applications (`BANKCRFM.RETAIL_LOAN_APPLICATIONS`), point-in-time on `APPLICATION_DT`, keys `*_RK`, valid-from `VALID_START_DT`, valid-to `VALID_END_DT` |
| Project (data set) | `RLA_APPLICATION`, subject Retail Application, Dec 31, 2024 Full build, 4,717 records |
| Variables | 58 + 2 + 38 + AGE + REJECT_FLG uploaded: `upload_variables_RLA_v2.xlsx`, `_v3a_DOB.xlsx`, `_v4_remaining.xlsx`, `_v3d_AGE_direct.xlsx`, `_v5b_REJECT_FLG_direct.xlsx` |
| Model 3 | `RLA_UD_MODEL` (target `APPLICATION_STATUS`, not used further) |
| Model 4 | `RLA_UD_MODEL2`, user-defined scorecard, target `REJECT_FLG`, Version 1 completed, deployment code generated Oct 26, 2026 12:11 PM, cut-off 521 |
| Scorecard bins and points | `scorecard_spec.md` |

## Scripts
`load_retail_loan_applications.sas`, `patch_age_gender.sas`, `add_age_column.sas`, `add_reject_flag.sas`, `backup_rla.sas`

## Not backed up by these files
The model and project definitions inside RM (the APDM metadata). Use any export option RM offers (see the chat notes) or rebuild from the files above.
