### ________________________________________________________________________________
#     Title: mod_hobos
#     Description: Shiny web app module to review and import hobo data to database
#     Written by: Dan Crocker
#     Last Updated: October 30, 2018
#
### ________________________________________________________________________________

### UI ###

HOBO_UI <- function(id) {
  ns <- NS(id) # see General Note 1
  tagList(
    useShinyjs(),
    div(
      id = "hobos", ### Set div() for Refresh Button ####
      title = "Tributary HOBO/MAYFLY Data Tool",
      fluidRow(
        column(
          12,
          actionButton(ns("refresh"), "REFRESH", align = "left"), ### Refresh button ####
          br(),
          textOutput(ns("intro")), ### Intro Text ####
          br()
        )
      ),
      fluidRow(
        column(
          4,
          strong(h4("1. SELECT A DATA FILE:")),
          uiOutput(ns("file.UI")), ### File UI ####
          verbatimTextOutput(ns("file_selection")), ### File selected text ####
          uiOutput(ns("stage.UI")) ### Stage UI ####
        ),
        column(
          4,
          strong(h4("2. PROCESS/REVIEW DATA:")),
          br(),
          uiOutput(ns("process.UI")), ### Process Button ####
          uiOutput(ns("text_process_status")) %>% withSpinner()
        ),
        column(
          4,
          strong(h4("3. IMPORT DATA:")),
          br(),
          uiOutput(ns("import.UI")), ### Import Button ####
          uiOutput(ns("text_import_status")) %>% withSpinner()
        )
      ),
      fluidRow( ### DATA TABSET PANELS
        column(
          12,
          tabsetPanel(
            tabPanel(
              "DATA PLOT",
              plotOutput(ns("plot"), width = "100%", height = "500px") %>% withSpinner(),
              uiOutput(ns("var2.UI")) ### PLOT PAGE ####
            ),
            tabPanel(
              "TABULAR DATA PREVIEW", ### DATA PREVEIW PAGE ####
              dataTableOutput(ns("table_data_preview"))
            ),
            tabPanel(
              "TABULAR FLAG DATA PREVIEW", ### FLAG DATA PREVIEW PAGE ####
              dataTableOutput(ns("table_flag_preview"))
            ),
            tabPanel(
              "TRIBUTARY MONITORING NOTES",
              dataTableOutput(ns("trib_monitoring"))
            )
          ) # End Tabset Panel
        ) # End Col
      ) # End FR
    ) # End Div
  ) # End Taglist
} # End UI  ####

################################ .
###         SERVER          ####
################################ .

HOBO <- function(input, output, session, hobo_path, updir, hobo_db, df_trib_monitoring, baro_table, hobo_table, mayfly_data_dir, mayfly_data_processed, ImportFlagTable, username, userlocation) { # Same as rating info - all in Hydro DB

  ### Source the HOBO functions ####
  source("ProcessHOBO.R", local = T) ### source Script ####

  ns <- session$ns

  ImportStatus <- reactiveVal("")

  rxvals <- reactiveValues()

  ### INTRO TEXT ####
  output$intro <- renderText({
    paste0("The HOBO/MAYFLY DATA TOOL is designed to facilitate the processing and importing of HOBO and MAYFLY Logger Data.\n 
                                       All raw text files exported from HOBO Ware should be checked over, corrections made with annotations prior to using this tool. \n
                                       Barometric files associated with water level files need to be imported first so that the compensation data is available to correct \n
                                       the water level data. All files successfully imported will be moved to an archive folder.")
  })

  #### FILE SELECTION ####

  # filter files to show only barometric files until there are none, and then show the other files
  # Make the File List

  rxvals$files <- get_files(updir, mayfly_data_dir)

  var2 <- reactive({
    input$var2
  })

  ### SET FILE TYPE ####
  # This determines what scripts are run to preview and process/import data
  if(userlocation == "Wachusett"){
  file_type <- reactive({
    req(input$file)
    x <- input$file
    if (str_detect(x, pattern = "(_BARO_).*\\.txt$")) {
      "baro" # Barometric hobo file selected
    } else if (str_detect(x, pattern = "^WACH-.{4}_\\d{8}-\\d{8}\\.csv$")) {
      "mayfly" # Regular hobo file selected
    } else {
      "hobo"
    }
  })
  }else{
    file_type <- reactive({
      req(input$file)
      x <- input$file
      if (str_detect(x, pattern = "(_BARO_).*\\.txt$")) {
        "baro" # Barometric hobo file selected
      } else if (str_detect(x, pattern = "^QUAB.*\\.csv$")) {
        "mayfly" # Regular hobo file selected
      } else {
        "hobo"
      }
    })
  }
  # str_detect(pattern = "(^.{4}MF_).*\\.csv$") = "mayfly" # Mayfly logger file selected

  ### Check to see if there are any BARO files to be processed
  baro_files <- reactive({
    req(rxvals$files)
    str_detect(rxvals$files, pattern = "(_BARO_).*\\.txt$") %>% any()
  })

  observe({
    print(glue("File selected is {input$file}..."))
    print(glue("File type is: {file_type()}..."))

    if (isFALSE(baro_files())) {
      show("stage")
    }
  })

  ### Files UI ####
  output$file.UI <- renderUI({
    req(rxvals$files)
    selectInput(
      inputId = ns("file"),
      label = "1. Choose file to upload:",
      choices = rxvals$files,
      selected = 1
    )
  })

  ###
  # Update Select Input when a file is imported (actually when the import button is pressed (successful or not))
  # observeEvent(input$import, {
  #   updateSelectInput(session = session,
  #                     inputId = ns("file"),
  #                     label = "1. Choose file to upload:",
  #                     choices = rxvals$files,
  #                     selected = "")
  # })
  ### Well File ####
  well_file <- reactive({
    req(input$file)
    str_detect(input$file, pattern = c("SYW177_.*\\.txt", "EPW2_.*\\.txt$")) %>% any()
  })

  wl_label <- reactive({
    req(input$file)
    wl_label <- if (well_file() == 0) {
      "Provide stage (ft) at time of download:"
    } else {
      "Provide Water Level Measurement (ft) at time of download:"
    }
  })

  ### Stage UI ####
  output$stage.UI <- renderUI({
    req(file_type() %in% c("hobo"))
    numericInput(
      inputId = ns("stage"),
      label = wl_label(), value = 0, min = 0, max = 30, step = 0.01, width = "100%"
    )
  })

  var2_choices <- reactive({
    req(file_type())
    if (file_type() == "hobo") {
      c("Discharge", "Temperature")
    } else if (file_type() == "mayfly") {
      c("Temperature", "Conductivity")
    }
  })

  ### Var2 UI ####
  output$var2.UI <- renderUI({
    req(file_type() %in% c("hobo", "mayfly"), well_file() == 0)
    radioButtons(
      inputId = ns("var2"),
      label = "Select the secondary Y axis value to plot:",
      choices = var2_choices(),
      selected = var2_choices()[1],
      inline = T,
      width = "100%"
    )
  })

  ### PROCESS UI ####

  output$process.UI <- renderUI({
    req(input$file)
    actionButton(
      inputId = ns("process"),
      label = paste0('Process "', input$file, '" Data'),
      width = "90%"
    )
  })

  # ### PLOT UI ####
  # output$plot_ui <- renderUI({
  #   req(dfs)
  #   plotOutput(ns("plot"), width = "100%", height = "500px")
  # })  

  ### RUN PROCESS FUNCTION ####
  # Run the function to process the data and return 2 dataframes and path as list
  dfs <- eventReactive(input$process, {
    switch(file_type(),
           "baro" = {
             PROCESS_BARO(baro_file = input$file, userlocation = userlocation)
           },
           "hobo" = {
             PROCESS_HOBO(hobo_txt_file = input$file, stage = input$stage, username = username, userlocation = userlocation)
           },
           "mayfly" = {
             PROCESS_MAYFLY(mayfly_file = input$file, username = username, userlocation = userlocation)
           }
    )
  }
  )
  
  
  ### RUN PREVIEW FUNCTION ####
  plot <- eventReactive(input$process, {
    req(dfs)
    switch(file_type(),
           "baro" = {
             PREVIEW_BARO(df(), df_prior(), var2 = NULL)
           },
           "hobo" = {
             PREVIEW_HOBO(df(), df_prior(), df_stage(), df_temp(), var2 = var2())
           },
           "mayfly" = {
             PREVIEW_MAYFLY(df(), df_prior(), df_stage(), df_temp(), df_conductivity(), var2 = var2())
           }
    )
  })
  
  #### PLOT OUTPUT ####
  output$plot <- renderPlot({
    req(try(df()))
    # plot()
    if (file_type() == "baro") {
      PREVIEW_BARO(df(), df_prior(), var2 = NULL)
    } else {
      switch(file_type(),
             "hobo" = {
               PREVIEW_HOBO(df(), df_prior(), df_stage(), df_temp(), var2 = var2())
             },
             "mayfly" = {
               PREVIEW_MAYFLY(df(), df_prior(), df_stage(), df_temp(), df_conductivity(), var2 = var2())
             }
      )
    }
  })
  
  ### Show Import Button ####                 
  observeEvent(input$process, {
    ImportStatus("")
    show(ns('import'))
    show(ns('table_data_preview'))
    show(ns('table_flag_preview'))
  })  
  
### FILE SELECTED ####
file_selected <- eventReactive(input$file, {
  input$file
})
# ### FILE PROCESSED ####
file_processed <- eventReactive(input$process, {
  input$file
})

### PROCESS STATUS ####
process_status <- reactive({
  if(input$file != file_processed()){
    " "
  }else if(inherits(try(dfs()), "try-error")){
    geterrmessage()
  }else{
    paste0('The file "', input$file, '" was successfully processed')
  }
})

### IMPORT STATUS ####
import_status <- reactive({
  ImportStatus()
})

### PROCESS OUTPUT DFS ####    
# Extract each dataframe
df <- reactive({
  dfs()[[1]]
})
df_flags <- reactive({ # Note - when there is no data the value here is 1
    dfs()[[2]]
})
df_prior <- reactive({
  dfs()[[3]]
})
df_stage <- reactive({
  dfs()[[4]]
})
df_temp <- reactive({
  dfs()[[5]]
})
df_conductivity <- reactive({
  dfs()[[6]]
})


### Import UI ####
# Import Action Button - Will only be shown when a file is processed successfully
output$import.UI <- renderUI({
  req(try(dfs()))
  actionButton(inputId = ns("import"),
               label = paste("Import", file_processed(), "Data"),
               width = '90%')
})

# Import Data - Run import_data function ####
observeEvent(input$import, {
  out <- tryCatch(
    switch(file_type(),
           "baro" = {IMPORT_BARO(df_baro = df(), baro_file = input$file, userlocation = userlocation)},
           "hobo" = {IMPORT_HOBO(df_hobo = df(), df_flags = df_flags(), hobo_txt_file = input$file, userlocation = userlocation)},
           "mayfly" = {IMPORT_MAYFLY(df_mayfly = df(), mayfly_file = input$file, userlocation = userlocation)}
    ),
    error = function(e) e)
  
  ImportFailed <- any(class(out) == "error")
  
  if (ImportFailed == TRUE){
    print(paste0("Import Failed at ", Sys.time() ,". There was an error: "))
    print(out)
    ImportStatus(paste0("Import Failed at ", Sys.time() ,". There was an error:\n", out))
  } else {
    print(paste0("Successful import of ", nrow(df()), " records in '", input$file, "' to Database at ", Sys.time()))
    ImportStatus(paste0("Successful import of ", nrow(df()), " records from file: '", input$file, "' to Database at ", Sys.time()))
  }
  rxvals$files <- get_files(updir, mayfly_data_dir)
  return(ImportStatus)
})
# Add text everytime successful import
# observeEvent(input$import, {
#   insertUI(
#     selector = ns("#import"),
#     where = "afterEnd",
#     ui = h4(paste("Successful import of", nrow(df()), "record(s) in '", input$file, "' to Database"))
#   )
# })

# Hide import button and tables when import button is pressed (So one cannot double import same file)
observeEvent(input$import, {
  hide(ns('import'))
  hide(ns('table_data_preview'))
  hide(ns('table_flag_preview'))
})


### Text Outputs ####
output$file_selection <- renderText({file_selected()})
output$text_process_status <- renderText({process_status()}) 
output$text_import_status <- renderText({
  req(try(import_status()))
  import_status()
})

observeEvent(input$refresh, {
  shinyjs::reset("hobos")
})


#### TABLE OUTPUTS ####

dt_colnames <- reactive({
  if (well_file() == 1) {
    c("ID", "Location", "Date-Time (UTC)", "Logger PSI", "Logger Temp (C)", "Water DBGS (ft)", "Water Elevation (ft")
  } else {
    switch(file_type(),
           "baro" = c("ID", "Location", "Date-Time (UTC)", "Logger PSI", "Logger Temp (C)"),
           "hobo" = c("ID", "Location", "Date-Time (UTC)", "Logger PSI", "Logger Temp (C)", "RawStage (ft)", "Stage (ft)", "Discharge (cfs)"),
           "mayfly" = c("ID", "Location", "Date-Time (UTC)", "Logger Temp (C)", "RawStage (ft)", "RawConductivity (uS/cm)")
    )
  }
})

### Processed data Table - Only make table if processing is successful
output$table_data_preview <- renderDataTable({
  req(try(df()))
  dt <- if (file_type() == "mayfly") {
    df()[, c(1:5, 8)]
  } else {
    df()
  }
  
  dt$DateTimeUTC <- as.character(format(dt$DateTimeUTC, format = "%Y-%m-%d %H:%M"))
  datatable(dt,
            colnames = dt_colnames(),
            rownames = FALSE,
            options = list(pageLength = 50)
  ) # %>%
  # formatDate(
  #   columns = "DateTimeUTC",
  #   method = 'toLocaleString')
  # method = 'toISOString')
  #   params = list("se", list(timeZone = "UTC", hour12 = FALSE))
  # )
})

### Processed Flag Table - Only make table if processing is successful
output$table_flag_preview <- renderDataTable({
  req(!df_flags() == 1)
  datatable(df_flags(), options = list(pageLength = 25))
})

### Trib Monitoring Table from Database
output$trib_monitoring <- renderDataTable({
  req(try(df_trib_monitoring))
  datatable(df_trib_monitoring, filter = "top", options = list(pageLength = 25))
})
} # end server function