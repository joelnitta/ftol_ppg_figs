source("R/packages.R")
source("R/functions.R")

# Makes plots for FTOL and PPG:
# - plot showing increase in GenBank fern sequences over time
# - plot showing participation in PPG

tar_plan(
  # GenBank ----
  # Analyze number of fern accessions and species in GenBank by type of DNA 
  # (plastid, mitochondrial, or nuclear)
  #
  # - Make dataframe of query terms by year
  gb_query = make_gb_query(),
  # - Download taxids one year at a time
  tar_target(
    gb_taxa,
    fetch_taxa_by_year(
      query = gb_query$query,
      year = gb_query$year,
      type = gb_query$type),
    pattern = map(gb_query)
  ),
  # - Load NCBI taxonomy
  tar_file_read(
    ncbi_names,
    "_targets/user/data_raw/taxdmp_2023-09-01.zip",
    load_ncbi_names(taxdump_zip_file = !!.x, taxid_keep = unique(gb_taxa$taxid))
  ),
  # - Count number of species and accessions in GenBank
  # by genomic compartment per year
  gb_species_by_year = count_ncbi_species_by_year(
    gb_taxa, ncbi_names, year_range = 1990:2022),
  # - Define fern tree sampling
  fern_tree_sampling_full = define_tree_sampling(),
  fern_tree_sampling_small = filter(
    fern_tree_sampling_full,
    source != "FTOL"),
  # - Make plots
  sampling_plot_full = make_gb_plot(
    gb_species_by_year, fern_tree_sampling_full
  ),
  sampling_plot_small = make_gb_plot(
    gb_species_by_year, fern_tree_sampling_small
  ),
  ppg_participants_plot = make_ppg_plot(),
  tar_file(
    sampling_plot_full_file,
    {
      ggsave(
      plot = sampling_plot_full, file = "results/sampling_plot_full.png",
      height = 14, width = 17, units = "cm")
      "results/sampling_plot_full.png"
    }
  ),
  tar_file(
    sampling_plot_small_file,
    {
      ggsave(
      plot = sampling_plot_small, file = "results/sampling_plot_small.png",
      height = 14, width = 17, units = "cm")
      "results/sampling_plot_small.png"
    }
  ),
  tar_file(
    ppg_participants_plot_file,
    {
      ggsave(
      plot = ppg_participants_plot, file = "results/ppg_participants.png",
      height = 14, width = 32, units = "cm")
      "results/ppg_participants.png"
    }
  )
)
