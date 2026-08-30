#include <gtk/gtk.h>

static void clicked(GtkButton *button, gpointer data) {
    gboolean *active = data;
    *active = !*active;
    gtk_button_set_label(button, *active ? "Clicked" : "Benchmark");
}

static void activate(GtkApplication *application, gpointer data) {
    (void)data;
    static gboolean active = FALSE;
    GtkWidget *window = gtk_application_window_new(application);
    gtk_window_set_title(GTK_WINDOW(window), "GTK benchmark");
    gtk_window_set_default_size(GTK_WINDOW(window), 480, 320);

    GtkWidget *button = gtk_button_new_with_label("Benchmark");
    gtk_widget_set_size_request(button, 160, 44);
    gtk_widget_set_halign(button, GTK_ALIGN_START);
    gtk_widget_set_valign(button, GTK_ALIGN_START);
    g_signal_connect(button, "clicked", G_CALLBACK(clicked), &active);
    gtk_window_set_child(GTK_WINDOW(window), button);
    gtk_window_present(GTK_WINDOW(window));
}

int main(int argc, char **argv) {
    g_set_prgname("dev.ourokit.benchmark.gtk");
    GtkApplication *application = gtk_application_new(
        "dev.ourokit.benchmark.gtk",
        G_APPLICATION_NON_UNIQUE
    );
    g_signal_connect(application, "activate", G_CALLBACK(activate), NULL);
    int status = g_application_run(G_APPLICATION(application), argc, argv);
    g_object_unref(application);
    return status;
}
