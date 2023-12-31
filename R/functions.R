# GenBank ----

#' Fetch metadata from GenBank
#'
#' @param query String to use for querying GenBank
#' @param col_select Character vector; columns of metadata to retain in output
#'
#' @return Tibble
#' 
fetch_metadata <- function(
  query = NULL,
  col_select = c("gi", "caption", "taxid", "title", "slen", "subtype", "subname")) {
  
  assertthat::assert_that(assertthat::is.string(query))
  
  assertthat::assert_that(is.character(col_select))
  
  # Do an initial search without downloading any IDs to see how many hits
  # we get.
  initial_genbank_results <- rentrez::entrez_search(
    db = "nucleotide",
    term = query,
    use_history = FALSE
  )
  
  # If no results, return empty tibble
  if (initial_genbank_results$count < 1) return(tibble(taxid = NA))
  
  # Download IDs with maximum set to 1 more than the total number of hits.
  genbank_results <- rentrez::entrez_search(
    db = "nucleotide",
    term = query,
    use_history = FALSE,
    retmax = initial_genbank_results$count + 1
  )
  
  # Define internal function to download genbank data into tibble
  # - make "safe" version of rentrez::entrez_summary to catch errors
  safe_entrez_summary <- purrr::safely(rentrez::entrez_summary)
  entrez_summary_gb <- function(id, col_select) {
    
    # Download data
    res <- safe_entrez_summary(db = "nucleotide", id = id)
    
    # Early exit if error with entrez
    if (!is.null(res$error)) {
      warning("No esummary records found in file, returning empty tibble")
      return(tibble(taxid = NA))
    }
    
    res$result %>%
      # Extract selected columns from result
      purrr::map_dfr(magrittr::extract, col_select) %>%
      # Make sure taxid column is character
      mutate(taxid = as.character(taxid)) %>%
      assert(not_na, taxid)
  }
  
  # Extract list of IDs from search results
  genbank_ids <- genbank_results$ids
  
  # Fetch metadata for each ID and extract selected columns
  if (length(genbank_ids) == 1) {
    rentrez_results <- rentrez::entrez_summary(db = "nucleotide", id = genbank_ids) %>%
      magrittr::extract(col_select) %>%
      tibble::as_tibble() %>%
      mutate(taxid = as.character(taxid)) %>%
      assert(not_na, taxid)
  } else {
    # Split input vector into chunks
    n <- length(genbank_ids)
    chunk_size <- 200
    r <- rep(1:ceiling(n/chunk_size), each = chunk_size)[1:n]
    genbank_ids_list <- split(genbank_ids, r) %>% magrittr::set_names(NULL)
    # Download results for each chunk
    rentrez_results <- map_df(genbank_ids_list, ~entrez_summary_gb(., col_select = col_select))
  }
  
  return(rentrez_results)
  
}


# Format a dataframe for searching GenBank for
# three types of fern sequences: plastid, nuclear, michondria
# from 1990 to 2023
make_gb_query <- function() {
  list(
    year = 1990:2023,
    query = c(
      "(Polypodiopsida[Organism] AND gene_in_plastid[PROP])",
      "(Polypodiopsida[Organism] gene_in_genomic[PROP])",
      "(Polypodiopsida[Organism] gene_in_mitochondrion[PROP])"
    )
  ) %>%
    cross_df() %>%
    mutate(
      type = case_when(
        str_detect(query, "plastid") ~ "plastid",
        str_detect(query, "genomic") ~ "nuclear",
        str_detect(query, "mito") ~ "mitochondrial",
      )
    )
}

# Get a tibble of taxids for a single year from genbank
fetch_taxa_by_year <- function(query, year, type) {
  full_query <- glue::glue('{query} AND ("{year}"[Publication Date] : "{year+1}"[Publication Date]) ')
  fetch_metadata(full_query, "taxid") %>%
    count(taxid) %>%
    mutate(type = type, year = year)
}

#' Load a dataframe of NCBI species names corresponding to taxon IDs
#' 
#' Excludes any taxon names that are not fully identified to species,
#' hybrid formulas, and environmental samples
#'
#' @param taxdump_zip_file Path to zip file with NCBI taxonomy database; must
#' contain a file called "names.dmp".
#' @param taxid_keep Character vector including the NCBI
#' taxids of the names to be extracted.
#'
#' @return Tibble with two columns, "taxid" and "species"
#' 
load_ncbi_names <- function(taxdump_zip_file, taxid_keep) {
  
  # Unzip names.dmp to a temporary directory
  temp_dir <- tempdir(check = TRUE)
  
  utils::unzip(
    taxdump_zip_file, files = "names.dmp",
    overwrite = TRUE, junkpaths = TRUE, exdir = temp_dir)
  
  # Load raw NCBI data
  ncbi_raw <-
    fs::path(temp_dir, "names.dmp") %>%
    readr::read_delim(
      delim = "\t|\t", col_names = FALSE,
      col_types = cols(.default = col_character())
    )
  
  # Delete temporary unzipped file
  fs::file_delete(fs::path(temp_dir, "names.dmp"))
  
  # Prune raw NBCI names to names in metadata
  ncbi_raw %>%
    # Select only needed columns
    transmute(
      taxid = as.character(X1),
      name = X2,
      class = X4) %>%
    # Filter to only taxid in genbank data
    filter(taxid %in% unique(taxid_keep)) %>%
    # Make sure there are no hidden fields in `class`
    verify(all(str_count(class, "\\|") == 1)) %>%
    # Drop field separators in `class`
    mutate(class = str_remove_all(class, "\\\t\\|")) %>%
    # Only keep accepted name
    filter(class == "scientific name") %>%
    # Exclude names from consideration that aren't fully identified to species, 
    # environmental samples, or hybrid formulas.
    # Hybrid names *can* be parsed:
    # - "Equisetum x ferrissii" (x before specific epithet)
    # - "x Cystocarpium roskamianum" (x before nothogenus)
    # Hybrid formulas *can't* be parsed:
    # - "Cystopteris alpina x Cystopteris fragilis" (x before another species)
    mutate(
      exclude = case_when(
        str_detect(name, " sp\\.| aff\\.| cf\\.| × [A-Z]| x [A-Z]|environmental sample") ~ TRUE,
        str_count(name, " ") < 1 ~ TRUE,
        TRUE ~ FALSE
      )
    ) %>%
    filter(exclude == FALSE) %>%
    select(-exclude) %>%
    select(taxid, species = name)
}

#' Count the number of species accumulated in GenBank each year by
#' genomic compartment
#'
#' @param gb_taxa Tibble with columns "taxid", "n" (number of accessions with
#' that ID), "type" (plastid, nuclear, or mitochondrial), and "year"
#' @param ncbi_names Tibble with columns "taxid" and "species" 
#' @param year_range Range of years to calculate
#'
#' @return Tibble with total number of species and accessions in genbank by year
#' for each type of genomic compartment
#' 
count_ncbi_species_by_year <- function(gb_taxa, ncbi_names, year_range) {
  
  # Filter GenBank taxaids to only those identified to species,
  # join to species names
  gb_species <-
    gb_taxa %>%
    filter(!is.na(taxid)) %>%
    inner_join(ncbi_names, by = "taxid")
  
  # Helper function to sum total species in each dataset
  # by year
  sum_species <- function(gb_species, year_select) {
    bind_rows(
      gb_species %>% filter(year <= year_select) %>%
        group_by(type) %>%
        summarize(
          n_species = n_distinct(species),
          n_acc = sum(n)
        ),
      gb_species %>% filter(year <= year_select) %>%
        summarize(
          n_species = n_distinct(species),
          n_acc = sum(n)
        ) %>%
        mutate(type = "total")
    ) %>%
      mutate(year = year_select)
  }
  
  # Count total number of accumulated species per year
  map_df(year_range, ~sum_species(gb_species, .))
}

define_tree_sampling <- function() {
  fern_tree_sampling <-
    tribble(
      ~source, ~date, ~n_species, ~label,
      "Hasebe 1995", "1995-01-01", 107, "Hasebe et al. 1995",
      "Schuettpelz 2007", "2007-01-01", 400, "Schuettpelz et al. 2007",
      "Lehtonen 2011", "2011-01-01", 2957, "Lehtonen 2011",
      "Testo 2016", "2016-01-01", 3973, "Testo and Sundue 2016",
      "FTOL", "2022-04-15", 5582, "FTOL v1.1.0",
      "FTOL", "2022-12-15", 5685, "FTOL v1.4.0",
      "FTOL", "2023-06-15", 5750, "FTOL v1.5.0"
    ) %>%
    mutate(
      source = fct_reorder(source, date),
      date = lubridate::ymd(date)
      )
  fern_tree_sampling
}

make_gb_plot <- function(gb_species_by_year, fern_tree_sampling) {
  
  gb_species_by_year <-  
    gb_species_by_year |>  
    filter(type == "plastid") |>
    mutate(
      date = paste0(year, "-01-01"),
      date = lubridate::as_date(date))

  genbank_plot <-
    ggplot(mapping = aes(x = date, y = n_species)) +
    geom_point(
      data = fern_tree_sampling,
      aes(shape = source),
      size = 2
    ) +
    geom_line(
      data = gb_species_by_year
    ) +
    scale_x_date(
      date_breaks = "5 years",
      labels = scales::label_date("%Y"),
      expand = expansion(0, 0)) + 
    scale_y_continuous(expand = expansion(0, 0)) +
    labs(shape = "代表的な論文", y = "種の数", x = "年") +
    coord_cartesian(clip = "off") +
    guides(shape = guide_legend(nrow = 2)) +
    theme_bw(
      base_size = 16,
      base_family = "HiraKakuPro-W3") +
    theme(
      panel.border = element_blank(),
      legend.position = "bottom",
      plot.margin = margin(r = 1, t = 0.5, l = 0.5, unit = "in")
    )
  genbank_plot
}

make_ppg_plot <- function() {
  # Load participant list
  ppg_com <- read_sheet(
    "https://docs.google.com/spreadsheets/d/1vxlmf8QPndiE6dIeDcjoFT7GA3ZE4pSc_Z1raf4iuwA/edit?usp=sharing"
    ) %>%
    clean_names() %>%
    mutate(
      country = str_replace_all(country, "USA", "United States of America") %>%
        str_replace_all("UK", "United Kingdom") %>%
        str_replace_all("Brunei Darussalam", "Brunei")
      )
  # Count participants by country
  ppg_count <- ppg_com %>%
    count(country)
  # Get number of participants in Japan
  n_japan <- ppg_com %>%
    filter(country == "Japan") %>%
    nrow()
  # Load world map
  world <- ne_countries(scale = "medium", returnclass = "sf")
  # So centroid calculations work
  sf_use_s2(FALSE)
  # Calculate centroids
  centroids <-
  world %>%
    filter(name_sort %in% ppg_com$country) %>%
    st_centroid() %>%
    left_join(ppg_count, by = c(name_sort = "country"))
  my_breaks <- c(5, 15, 30, 45)
  # Make plot
  plot <- 
    ggplot() +
    geom_sf(data = world, fill = "transparent", color = "grey50") +
    geom_point(
      data = centroids,
      aes(size = n, fill = n, geometry = geometry),
      shape = 21,
      stat = "sf_coordinates") +
    scale_size_continuous(
      name = "人数",
      breaks = my_breaks,
      labels = my_breaks
    ) +
    scale_fill_viridis_c(
      option = "viridis",
      name = "人数",
      breaks = my_breaks,
      labels = my_breaks
    ) +
    guides(fill = guide_legend(), size = guide_legend())  +
    theme_gray(
      base_size = 18,
      base_family = "HiraKakuPro-W3") +
    theme(
      plot.background = element_rect(fill = "transparent"),
      panel.background = element_rect(fill = "transparent"),
      axis.title = element_blank(),
      legend.key = element_rect(fill = "transparent")
    )
  plot
}