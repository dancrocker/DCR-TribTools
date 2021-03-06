################################### HEADER ###################################
#  TITLE: ProcessMayflyData
#  DESCRIPTION: Reads mayfly logger csv file, calculates discharge, reformats for database
#  AUTHOR(S):
#  DATE LAST UPDATED:
#  GIT REPO:
#  R version 3.5.3 (2019-03-11)  i386
##############################################################################.

# mayfly_files <- list.files(config[16]) %>% print()
# mayfly_file <- mayfly_files[4]
# username <- "Dan Crocker"
# stage <- 1.26 ### Enter stage at time of data download (Numeric entry in Shiny App)
#   
PROCESS_MAYFLY <- function(mayfly_file, stage, username, userlocation){
  
print(paste0("Mayfly data started processing at ", Sys.time()))
  
### Extract the location information from the Plot Title listed in the file
file <- paste0(mayfly_data_dir,"/", mayfly_file)

loc <- str_split_fixed(mayfly_file, "MF_", n = 2) 
loc <- loc[,1]

df <- read_csv(file, skip = 7, guess_max = 100, 
               col_types = cols(
                 `Date and Time in UTC-5` = col_character(),
                 CTDcond = col_double(),
                 CTDdepth = col_double(),
                 CTDtemp = col_double()
               )) %>%   
  select(c(1:4)) %>% 
  drop_na() %>%
  mutate("Location" = loc, "ID" = NA_integer_)

names(df) <- c("DateTimeUTC", "Conductivity_uScm", "Stage_ft", "Logger_temp_c", "Location","ID")

### Format Date-Time stamp
df$DateTimeUTC <- parse_date_time(df$DateTimeUTC,"%y-%m-%d %H:%M:%S", tz = "America/Lima" ) # Use lima (UTC-5 to convert times - this avoids EST for America/New_York)
df$DateTimeUTC <- as_datetime(df$DateTimeUTC, tz = "UTC")

### Convert Stage from mm to ft
df$Stage_ft <- df$Stage_ft/304.8

### Connect to db in UTC time
database <- "DCR_DWSP"
con <- dbConnect(odbc::odbc(), database, timezone = 'UTC')
schema <- userlocation                 
mayfly_tbl <- "tblMayfly"

### A function to fetch record IDs from the database table and assign record IDs to the new data
setIDs <- function(){
  qry <- dbGetQuery(con, glue("SELECT max(ID) FROM [{schema}].[{mayfly_tbl}]"))
  
  ### Get current max ID
  if(is.na(qry)) {
    qry <- 0
  } else {
    qry <- qry
  }
  ID_max <- as.numeric(unlist(qry))
  rm(qry)
  
  ### Set IDs
  df$ID <- seq.int(nrow(df)) + ID_max
}
df$ID <- setIDs()


### Find the last time-stamp
end_time <- max(df$DateTimeUTC)

### get the last raw stage value using the end time
last_stage <- df$Stage_ft[df$DateTimeUTC == end_time]

### Calculate the stage offset to be applied to each raw stage (stage is a function argument)
offset <- stage - last_stage

### Calculate the final stage using the offset
df$Stage_ft <- round(df$Stage_ft + offset, digits = 2)

source("HOBO_calcQ.R")
  ### Calcualte all discharges and save df
  df <- HOBOcalcQ(schema = "Wachusett", loc = loc, df_HOBO = df)

### Make a flag df if there are any discharge related flags (only above/below rating curve can be automatically calculated)
setFlagIDs <- function(){
  if(all(is.na(df$RatingFlag)) == FALSE){ # Condition returns FALSE if there is at least 1 non-NA value, if so proceed
    ### Split the flags into a separate df and assign new ID
    df_flags <- df[,c("ID","RatingFlag")] %>%
      rename("SampleID" = ID, "FlagCode" = RatingFlag) %>%
      drop_na()
    
    query.flags <- dbGetQuery(con, glue("SELECT max(ID) FROM [{schema}].[{ImportFlagTable}]"))
    # Get current max ID
    if(is.na(query.flags)) {
      query.flags <- 0
    } else {
      query.flags <- query.flags
    }
    ID.max.flags <- as.numeric(unlist(query.flags))
    rm(query.flags)
    
    ### ID flags
    df_flags$ID <- seq.int(nrow(df_flags)) + ID.max.flags
    df_flags$DataTableName <- mayfly_table
    df_flags$DateFlagged <-  Sys.Date()
    df_flags$ImportStaff <-  username
    df_flags$Comment <- "Flags generated during data import"
    
    # Reorder df_flags columns to match the database table exactly # Add code to Skip if no df_flags
    df_flags <- df_flags[,c(3,4,1,2,5,6,7)]

  } else {
    df_flags <- NA
  }
} # End set flags function
df_flags <- setFlagIDs()

### df_Stage ####

### Connect to db  in America/New_York tz
con <- dbConnect(odbc::odbc(), database, timezone = 'America/New_York')

df_stage <- dbGetQuery(con, glue("SELECT [Location], [DateTimeET], [Parameter], [FinalResult] 
                                  FROM [{schema}].[tblTribFieldParameters] WHERE [Parameter] = 'Staff Gauge Height'
                                  AND [Location] = '{loc}'"))
### Disconnect from db and remove connection obj
dbDisconnect(con)
rm(con)

df_stage <- df_stage %>% 
  filter(DateTimeET > min(df$DateTimeUTC),
         DateTimeET < max(df$DateTimeUTC))

### df_prior ####

### Grab last 1 days records to plot with new data to check for missed data corrections
t <- min(df$DateTimeUTC)
con <- dbConnect(odbc::odbc(), database, timezone = 'UTC')

mayfly_prior <- dbGetQuery(con, glue("SELECT * FROM [{schema}].[{mayfly_tbl}] WHERE 
                                  [Location] = '{loc}'"))
  
# hobo_prior$DateTimeUTC <-  force_tz(hobo_prior$DateTimeUTC, tzone = "UTC") 
mayfly_prior <- filter(mayfly_prior, Location == loc, DateTimeUTC >= (t - 86400), DateTimeUTC < t)

### Reorder columns to match db
col_order <- c(dbListFields(con, schema_name = schema, name = mayfly_tbl))
df <-  df[col_order]

### Disconnect from db and remove connection obj
dbDisconnect(con)
rm(con)

dfs <- list(
  "df" = df,
  "df_flag" = df_flags,
  "df_prior" = mayfly_prior,
  "df_stage" = df_stage)

print(paste0("Mayfly Data finished processing at ", Sys.time()))

return(dfs)

}

### Run funciton locally, comment out when deployed in Shiny

# dfs <- PROCESS_MAYFLY(mayfly_file = mayfly_file , stage = 1.26, username = "Dan Crocker", userlocation = userlocation)

PREVIEW_MAYFLY <- function(df_mayfly, df_prior = NULL, df_stage = NULL, var2 = NULL) {
  
  pd <- df_mayfly
  
  loc <- df_mayfly %>% 
    slice(1) %>% 
    pull(Location)
  
  cols <- c("Water Temperature (C)" = "purple4",
            "Water Temperature (C) - prior" = "orchid4",
            "Discharge (cfs)" = "blue4", 
            "Discharge (cfs) - prior" = "steelblue",
            "Stage (ft)" = "darkgreen",
            "Stage (ft) - prior" = "darkseagreen4",
            "Stage (ft) - manual" = "darkorange3",
            "Conductivity (uS/cm)" = "darkslateblue", 
            "Conductivity (uS/cm) - prior" = "darkorchid4" 
  )
  if(nrow(df_prior) == 0){
    prior <-  FALSE
  } else {
    prior <-  TRUE
  }
  
  y1lim <- max(pd$Stage_ft)
  
  y2lim <- switch (var2,
    "Temperature" = max(pd$Logger_temp_c),
    "Conductivity" = max(pd$Conductivity_uScm),
    "Discharge" = max(pd$Discharge_cfs)
  )
  
  title <- switch (var2,
    "Temperature" = paste0("Stage and Water Temperature at Location ", loc),
    "Conductivity" = paste0("Stage and Specific Conductance at Location ", loc),
    "Discharge" = paste0("Stage and Discharge at Location ", loc)
  )
  
  mult <- y1lim / abs(y2lim)
  
  plot  <- ggplot(pd, aes(x = DateTimeUTC)) +
    geom_line(aes(y = Stage_ft, color = "Stage (ft)"), size = 1)  
  
  plot <- switch (var2,
        "Temperature" = plot + geom_line(aes(y = Logger_temp_c * mult, color = "Water Temperature (C)"), size = 1),
        "Conductivity" = plot + geom_line(aes(y = Conductivity_uScm * mult, color = "Conductivity (uS/cm)"), size = 1),
        "Discharge" = plot + geom_line(aes(y = Discharge_cfs * mult, color = "Discharge (cfs)"), size = 1)
    )

  # Check for prior data to plot 
  if(isTRUE(prior)){
    plot <- plot +  
      geom_line(data = df_prior, aes(x = DateTimeUTC, y = Stage_ft, color = "Stage (ft) - prior"), size = 1) +
      geom_vline(xintercept = min(DateTimeUTC), color = "gray10", linetype = 2, size = 1.5, alpha = 0.8)

  plot <- switch (var2,
      "Temperature" = plot + geom_line(data = df_prior, aes(x = DateTimeUTC, y = df_prior$Logger_temp_c * mult, color = "Water Temperature (C) - prior"), size = 1),
      "Conductivity" = plot + geom_line(data = df_prior, aes(x = DateTimeUTC, y = df_prior$Conductivity_uScm * mult, color = "Conductivity (uS/cm) - prior"), size = 1),
      "Discharge" = plot + geom_line(data = df_prior, aes(x = DateTimeUTC, y = df_prior$Discharge_cfs * mult, color = "Discharge (cfs) - prior"), size = 1) 
    )    
  }
  if(nrow(df_stage) > 0){
    plot <- plot + 
      geom_point(data = df_stage, aes(x = DateTimeET, y = FinalResult, color = "Stage (ft) - manual"), size = 2)
  } ### NOTE Manual stage gets converted to UTC during import, so it is plotted correctly on the x-axis in UTC time along with sensor data
  plot <- plot +    
    scale_y_continuous(breaks = pretty_breaks(),limits = c(0, 1.2 * y1lim), 
                       sec.axis = sec_axis(~./mult, breaks = pretty_breaks(), name = var2)) +
    scale_x_datetime(breaks = pretty_breaks(n=12)) + 
    scale_colour_manual(values = cols) +
    labs(y = "Stage (ft)",
         x = "Date",
         colour = "") +
    ggtitle(title) +
    theme_linedraw() +
    theme(plot.title = element_text(color= "black", face="bold", size=14, vjust = 1, hjust = 0.5),
          legend.position = "bottom",
          axis.title.x = element_text(angle = 0, face = "bold", color = "black"),
          axis.title.y = element_text(angle = 90, face = "bold", color = "black"))
  
  # plot
  return(plot)
}

# df_mayfly <- dfs[[1]]
# df_stage <- dfs[[4]]
# df_prior <- dfs[[3]]
# var2 <- "Temperature"
# plot <- PREVIEW_MAYFLY(df_mayfly = df_mayfly, df_stage = df_stage, df_prior = df_prior, var2 = var2)
# plot
# Comment out if running in shiny
# df_mayfly <- PROCESS_HOBO(hobo_file = hobo_file, stage = stage)


IMPORT_MAYFLY <- function(df_mayfly, df_flags, mayfly_file, userlocation){
  print(paste0("Mayfly Data started importing at ", Sys.time()))
  
  file <- paste0(mayfly_data_dir,"/", mayfly_file)
  
  loc <- str_split_fixed(mayfly_file, "MF_", n = 2) 
  loc <- loc[,1]
  
  mayfly_tbl <- "tblMayfly"
  
  database <- "DCR_DWSP" 
  schema <- userlocation
  con <- dbConnect(odbc::odbc(), database, timezone = 'UTC')
  odbc::dbWriteTable(con, DBI::SQL(glue("{database}.{schema}.{mayfly_tbl}")), value = df_mayfly, append = TRUE)
  
  # Flag data
  if ("data.frame" %in% class(df_flags)){ # Check and make sure there is flag data to import
    print("Importing flags...")
    odbc::dbWriteTable(con, DBI::SQL(glue("{database}.{schema}.{ImportFlagTable}")), value = df_flags, append = TRUE)
  } else {
    print("No flags to import")
  }
  # Disconnect from db and remove connection obj
  dbDisconnect(con)
  rm(con)
  
  ### Move the processed raw mayfly data file to the appropriate processed folder
  dir_num <- as.numeric(which(!is.na(str_match(list.dirs(mayfly_data_processed, recursive = T, full.names = T), loc))))
  subdir <- list.dirs(mayfly_data_processed, recursive = T, full.names = T)[dir_num]
  
  file.rename(file, paste0(subdir, "/", mayfly_file))
  print(paste0("Mayfly Data finished importing at ", Sys.time()))
  return("Import Successful")
}
  
  
  
  