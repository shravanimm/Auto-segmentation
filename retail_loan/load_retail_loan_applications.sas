/* load_retail_loan_applications.sas
   Reads retail_loan_applications.csv (50,000 rows, 104 columns) from SAS Content,
   converts the 4 date columns to SAS datetimes (informat ANYDTDTM19., format NLDATM21.),
   renames 2 over-long column names, and publishes BANKCRFM.RETAIL_LOAN_APPLICATIONS.
   Run in SAS Studio after uploading the CSV to /Users/sastest1/My Folder. */

cas ld1;
caslib _all_ assign;

filename src filesrvc folderpath="/Users/sastest1/My Folder" filename="retail_loan_applications.csv";

data work.retail_loan_applications;
  infile src dsd dlm=',' firstobs=2 truncover lrecl=32767;
  length application_id 8 application_dt 8;
  length
    application_status $29 application_origin $10 channel $10 request_source $15 entity $16 priority $8
    simulation_flag $8 customer_type $19 customer_industry $17 vip_flag $8 requested_currency $8
    refinance_flag $8 loan_purpose $24 product_category $12 product_code $12 credit_range $13 first_name $10
    middle_name $8 last_name $10 gender $8 marital_status $10 nationality $8 country_of_residence $8 country
    $8 residential_status $11 education $8 home_ownership $8 politically_exposed_person $8 residential_street
    $10 residential_city $8 residential_postal_code $8 email $38 phone $11 employer_name $11 job_title $10
    occupation $8 employment_status $19 employment_type $12 employment_industry $8 liability_type $15
    worst_status_12m $10 record_type $8 record_status $8 inquiry_product $15 inquiry_type $8
    credit_line_product $15 credit_line_status $8 outcome_cd $29;
  informat
    application_id best32. application_date $19. application_status $29. application_origin $10. channel $10.
    request_source $15. entity $16. priority $8. simulation_flag $8. customer_id best32. customer_type $19.
    customer_industry $17. existing_customer_since $19. vip_flag $8. requested_amount best32.
    requested_down_payment best32. requested_ltv best32. requested_interest_rate best32. requested_term
    best32. requested_currency $8. balance_transfer_amount best32. refinance_flag $8. loan_purpose $24.
    product_category $12. product_code $12. credit_range $13. applicant_id best32. first_name $10. middle_name
    $8. last_name $10. gender $8. date_of_birth $19. marital_status $10. nationality $8. country_of_residence
    $8. country $8. residential_status $11. education $8. dependants best32. home_ownership $8.
    politically_exposed_person $8. residential_street $10. residential_street_number best32. residential_city
    $8. residential_postal_code $8. email $38. phone $11. employer_name $11. job_title $10. occupation $8.
    employment_status $19. employment_type $12. employment_industry $8. employment_start_date $19.
    monthly_employment_income best32. monthly_allowance_income best32. total_monthly_income best32.
    total_income_declared best32. monthly_rent best32. monthly_groceries best32. total_monthly_expenses
    best32. total_expenses_declared best32. liquid_assets best32. liability_type $15. liability_amount best32.
    liability_credit_limit best32. bureau_score best32. total_inquiries best32. inquiries_30_days best32.
    inquiries_90_days best32. inquiries_180_days best32. inquiries_365_days best32. defaults_count best32.
    default_amount best32. delinquent_amount best32. bureau_total_liab_balance best32. bureau_liability_amount
    best32. limit_amount best32. unsecured_balance best32. worst_status_12m $10. public_records_count best32.
    bureau_public_record_amount best32. record_type $8. record_status $8. record_amount best32.
    inquiry_product $15. inquiry_type $8. inquiry_amount best32. credit_line_product $15. credit_line_limit
    best32. outstanding_balance best32. installment_amount best32. credit_line_term best32. credit_line_status
    $8. past_due_amount best32. total_credit_balance best32. rel_total_liab_balance best32. total_deposits
    best32. total_open_accounts best32. total_open_credit_accounts best32. monthly_installment_total best32.
    average_credit_balance_365 best32. worst_delinquency_12m best32. outcome_cd $29.;
  input
    application_id application_date application_status application_origin channel request_source entity
    priority simulation_flag customer_id customer_type customer_industry existing_customer_since vip_flag
    requested_amount requested_down_payment requested_ltv requested_interest_rate requested_term
    requested_currency balance_transfer_amount refinance_flag loan_purpose product_category product_code
    credit_range applicant_id first_name middle_name last_name gender date_of_birth marital_status nationality
    country_of_residence country residential_status education dependants home_ownership
    politically_exposed_person residential_street residential_street_number residential_city
    residential_postal_code email phone employer_name job_title occupation employment_status employment_type
    employment_industry employment_start_date monthly_employment_income monthly_allowance_income
    total_monthly_income total_income_declared monthly_rent monthly_groceries total_monthly_expenses
    total_expenses_declared liquid_assets liability_type liability_amount liability_credit_limit bureau_score
    total_inquiries inquiries_30_days inquiries_90_days inquiries_180_days inquiries_365_days defaults_count
    default_amount delinquent_amount bureau_total_liab_balance bureau_liability_amount limit_amount
    unsecured_balance worst_status_12m public_records_count bureau_public_record_amount record_type
    record_status record_amount inquiry_product inquiry_type inquiry_amount credit_line_product
    credit_line_limit outstanding_balance installment_amount credit_line_term credit_line_status
    past_due_amount total_credit_balance rel_total_liab_balance total_deposits total_open_accounts
    total_open_credit_accounts monthly_installment_total average_credit_balance_365 worst_delinquency_12m
    outcome_cd;

  /* text -> SAS datetime (seconds since 01Jan1960) */
  application_dt             = input(application_date,         anydtdtm19.);
  existing_customer_since_dt = input(existing_customer_since,  anydtdtm19.);
  date_of_birth_dt           = input(date_of_birth,            anydtdtm19.);
  employment_start_dt        = input(employment_start_date,    anydtdtm19.);
  format application_dt existing_customer_since_dt date_of_birth_dt employment_start_dt nldatm21.;
  format application_id customer_id applicant_id 12.;
  /* open-ended valid-to date (31Dec4747:23:59:59), same value ALL_APPLICATION_DIM uses; RM point-in-time needs a Valid-to column */
  valid_end_dt = 87980687999;
  format valid_end_dt nldatm21.;
  drop application_date existing_customer_since date_of_birth employment_start_date;
run;

/* checks on the work copy */
proc sql;
  select count(*) as n_rows, count(distinct application_id) as n_ids,
         sum(missing(application_dt)) as n_bad_dt,
         min(application_dt) format=nldatm21. as first_dt,
         max(application_dt) format=nldatm21. as last_dt
  from work.retail_loan_applications;
  select count(*) as dec_2024 from work.retail_loan_applications
  where application_dt between '01DEC2024:00:00:00'dt and '31DEC2024:23:59:59'dt;
quit;

/* load to CAS and publish (our own new table, nothing existing is touched) */
data CASUSER.RETAIL_LOAN_APPLICATIONS;
  set work.retail_loan_applications;
run;

proc casutil incaslib="CASUSER" outcaslib="BANKCRFM";
  droptable incaslib="BANKCRFM" casdata="RETAIL_LOAN_APPLICATIONS" quiet;
  save casdata="RETAIL_LOAN_APPLICATIONS" casout="RETAIL_LOAN_APPLICATIONS" replace;
  promote casdata="RETAIL_LOAN_APPLICATIONS" casout="RETAIL_LOAN_APPLICATIONS";
quit;

proc cas;
  table.columnInfo / table={caslib="BANKCRFM", name="RETAIL_LOAN_APPLICATIONS"};
quit;
