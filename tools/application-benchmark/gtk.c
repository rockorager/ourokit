#include <gtk/gtk.h>
#include <string.h>

static gboolean settings_mode = FALSE;

static void clicked(GtkButton *button, gpointer data) {
    gboolean *active = data;
    *active = !*active;
    gtk_button_set_label(button, *active ? "Clicked" : "Benchmark");
}

static void increment_settings(GtkButton *button, gpointer data) {
    (void)button;
    static guint count = 0;
    char label[32];
    g_snprintf(label, sizeof(label), "Pressed %u times", ++count);
    gtk_label_set_text(GTK_LABEL(data), label);
}

static void activate(GtkApplication *application, gpointer data) {
    (void)data;
    static gboolean active = FALSE;
    GtkWidget *window = gtk_application_window_new(application);
    if (settings_mode) {
        gtk_window_set_title(GTK_WINDOW(window), "GTK settings benchmark");
        gtk_window_set_default_size(GTK_WINDOW(window), 560, 360);
        GtkWidget *column = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
        gtk_widget_set_margin_start(column, 12);
        gtk_widget_set_margin_top(column, 12);
        GtkWidget *heading = gtk_label_new("Ourokit controls");
        gtk_widget_set_halign(heading, GTK_ALIGN_START);
        gtk_box_append(GTK_BOX(column), heading);
        GtkWidget *status = gtk_label_new("Pressed 0 times");
        gtk_widget_set_halign(status, GTK_ALIGN_START);
        gtk_box_append(GTK_BOX(column), status);
        GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
        GtkWidget *increment = gtk_button_new_with_label("Increment");
        gtk_widget_set_size_request(increment, 160, 40);
        g_signal_connect(increment, "clicked", G_CALLBACK(increment_settings), status);
        GtkWidget *disabled = gtk_button_new_with_label("Disabled");
        gtk_widget_set_size_request(disabled, 160, 40);
        gtk_widget_set_sensitive(disabled, FALSE);
        gtk_box_append(GTK_BOX(row), increment);
        gtk_box_append(GTK_BOX(row), disabled);
        gtk_box_append(GTK_BOX(column), row);
        gtk_window_set_child(GTK_WINDOW(window), column);
        gtk_window_present(GTK_WINDOW(window));
        return;
    }
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
    if (argc == 2 && strcmp(argv[1], "--settings") == 0) {
        settings_mode = TRUE;
        argc = 1;
    }
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
